#!/usr/bin/env pwsh
# =============================================================================
# LLM Backend Onboarding — Import Existing Resources
#
# Imports Azure resources that already exist (e.g., from the main Citadel
# deployment) into this module's Terraform state. This enables the onboarding
# module to update resources that were initially created by the main deployment.
#
# Usage:
#   ./scripts/import-existing.ps1 [-VarFile FILE]
#
# Called automatically by deploy.ps1 before plan/apply.
# =============================================================================

[CmdletBinding()]
param(
    [string]$VarFile = 'terraform.tfvars'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Colour helpers ---
function Write-Info    { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Blue }
function Write-Success { param([string]$Message) Write-Host "[OK]    $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Err     { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red; exit 1 }

# Safely read a property from a PSCustomObject without tripping Set-StrictMode.
function Get-Prop {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir
Set-Location $RootDir

# --- Extract a scalar variable value from the tfvars file ---
function Get-TfVar {
    param([string]$Name)
    $m = Select-String -Path $VarFile -Pattern "^\s*$Name\s*=" | Select-Object -First 1
    if ($m -and $m.Line -match '=\s*"([^"]*)"') { return $Matches[1] }
    return ''
}

$SubscriptionId = Get-TfVar 'subscription_id'
$ResourceGroup  = Get-TfVar 'resource_group_name'
$ApimName       = Get-TfVar 'apim_name'

if (-not $SubscriptionId -or -not $ResourceGroup -or -not $ApimName) {
    Write-Err "Could not extract subscription_id, resource_group_name, or apim_name from $VarFile"
}

$ApimBaseId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"

Write-Info 'Checking for existing resources to import...'
Write-Info "  APIM: $ApimName in $ResourceGroup"

$script:Imported = 0
$script:Skipped  = 0
$script:NotFound = 0

# --- Helper: try to import a resource if it exists in Azure but not in state ---
function Invoke-TryImport {
    param([string]$TfAddress, [string]$AzureId)

    # Check if already in Terraform state
    terraform state show $TfAddress *> $null
    if ($LASTEXITCODE -eq 0) {
        $script:Skipped++
        return
    }

    # Check if resource exists in Azure
    az rest --method GET --url "https://management.azure.com${AzureId}?api-version=2024-06-01-preview" *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "  Importing: $TfAddress"
        terraform import -var-file="$VarFile" $TfAddress $AzureId *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "  Imported: $TfAddress"
            $script:Imported++
        }
        else {
            Write-Warn "  Failed to import: $TfAddress (will be recreated)"
        }
    }
    else {
        $script:NotFound++
    }
}

# --- Import LLM Backends ---
# Extract backend_id values from the tfvars file.
$BackendIds = Select-String -Path $VarFile -Pattern 'backend_id' | ForEach-Object {
    if ($_.Line -match '=\s*"([^"]*)"') { $Matches[1] }
}

foreach ($backendId in $BackendIds) {
    if (-not $backendId) { continue }
    Invoke-TryImport `
        "azapi_resource.llm_backend[`"$backendId`"]" `
        "$ApimBaseId/backends/$backendId"
}

# --- Import Dynamic Policy Fragments ---
$DynamicFragments = @('set-backend-pools', 'get-available-models', 'metadata-config')
$TfDynamicNames   = @('set_backend_pools', 'get_available_models', 'metadata_config')

for ($i = 0; $i -lt $DynamicFragments.Count; $i++) {
    Invoke-TryImport `
        "azurerm_api_management_policy_fragment.$($TfDynamicNames[$i])" `
        "$ApimBaseId/policyFragments/$($DynamicFragments[$i])"
}

# --- Import Static Policy Fragments ---
$StaticFragments = @(
    'set-backend-authorization', 'set-target-backend-pool', 'set-llm-requested-model',
    'set-llm-usage', 'validate-model-access', 'responses-id-security', 'responses-id-cache-store'
)

foreach ($frag in $StaticFragments) {
    Invoke-TryImport `
        "azurerm_api_management_policy_fragment.static[`"$frag`"]" `
        "$ApimBaseId/policyFragments/$frag"
}

# --- Import resolve-model-alias Policy Fragment (own resource block) ---
Invoke-TryImport `
    'azurerm_api_management_policy_fragment.resolve_model_alias' `
    "$ApimBaseId/policyFragments/resolve-model-alias"

# --- Import AWS Bedrock Named Values (always created with safe defaults) ---
$AwsNamedValues = @('aws-access-key', 'aws-secret-key', 'aws-region')
$TfAwsNames     = @('aws_access_key', 'aws_secret_key', 'aws_region')

for ($i = 0; $i -lt $AwsNamedValues.Count; $i++) {
    Invoke-TryImport `
        "azurerm_api_management_named_value.$($TfAwsNames[$i])" `
        "$ApimBaseId/namedValues/$($AwsNamedValues[$i])"
}

# --- Import Dynamic Backend API-Key Named Values ---
# Derived from auth_config.named_value_key entries in the tfvars file.
$NamedValueKeys = Select-String -Path $VarFile -Pattern 'named_value_key' | ForEach-Object {
    if ($_.Line -match '=\s*"([^"]*)"') { $Matches[1] }
}

foreach ($nvKey in $NamedValueKeys) {
    if (-not $nvKey) { continue }
    Invoke-TryImport `
        "azurerm_api_management_named_value.backend_api_key[`"$nvKey`"]" `
        "$ApimBaseId/namedValues/$nvKey"
}

# --- Import Backend Pools (if any exist) ---
# Pool names are derived from model names — discover them from Azure.
$PoolNames = @()
$backendsJson = az rest --method GET --url "https://management.azure.com$ApimBaseId/backends?api-version=2024-06-01-preview" 2>$null | Out-String
if ($backendsJson.Trim()) {
    try {
        $parsed = $backendsJson | ConvertFrom-Json
        foreach ($b in (Get-Prop $parsed 'value')) {
            $props = Get-Prop $b 'properties'
            if ((Get-Prop $props 'type') -eq 'Pool') {
                $name = Get-Prop $b 'name'
                if ($name) { $PoolNames += $name }
            }
        }
    } catch { }
}

foreach ($poolName in $PoolNames) {
    Invoke-TryImport `
        "azapi_resource.llm_backend_pool[`"$poolName`"]" `
        "$ApimBaseId/backends/$poolName"
}

# --- Summary ---
Write-Host ''
if ($script:Imported -gt 0) {
    Write-Success "Import complete: $($script:Imported) imported, $($script:Skipped) already in state, $($script:NotFound) not found in Azure."
}
else {
    Write-Info "No imports needed: $($script:Skipped) already in state, $($script:NotFound) not found in Azure."
}
