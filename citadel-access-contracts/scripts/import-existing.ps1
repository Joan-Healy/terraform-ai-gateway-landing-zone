#!/usr/bin/env pwsh
# =============================================================================
# Citadel Access Contracts — Import Existing Resources
#
# Imports APIM resources that already exist (e.g., from a previous onboarding
# run whose state was lost, or resources created out-of-band) into this
# module's Terraform state, so they are updated rather than recreated.
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

# --- Extract a field from a named HCL object block in the tfvars file ---
# Get-BlockField <block_name> <field_name>
function Get-BlockField {
    param([string]$Block, [string]$Field)
    $inBlock = $false
    foreach ($line in (Get-Content -LiteralPath $VarFile)) {
        if ($line -match "^\s*$Block\s*=\s*\{") { $inBlock = $true; continue }
        if ($inBlock -and $line -match '^\s*\}') { $inBlock = $false }
        if ($inBlock -and $line -match "^\s*$Field\s*=") {
            if ($line -match '=\s*"([^"]*)"') { return $Matches[1] }
        }
    }
    return ''
}

$SubscriptionId = Get-BlockField 'apim' 'subscription_id'
$ResourceGroup  = Get-BlockField 'apim' 'resource_group_name'
$ApimName       = Get-BlockField 'apim' 'name'

$BusinessUnit = Get-BlockField 'use_case' 'business_unit'
$UseCaseName  = Get-BlockField 'use_case' 'use_case_name'
$Environment  = Get-BlockField 'use_case' 'environment'

if (-not $SubscriptionId -or -not $ResourceGroup -or -not $ApimName) {
    Write-Err "Could not extract apim.subscription_id / resource_group_name / name from $VarFile"
}
if (-not $BusinessUnit -or -not $UseCaseName -or -not $Environment) {
    Write-Err "Could not extract use_case.business_unit / use_case_name / environment from $VarFile"
}

$Postfix    = "$BusinessUnit-$UseCaseName-$Environment"
$ApimBaseId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"

Write-Info 'Checking for existing resources to import...'
Write-Info "  APIM:     $ApimName in $ResourceGroup"
Write-Info "  Use case: $Postfix"

# --- Service codes (within the services = [...] block) ---
$ServiceCodes = Select-String -Path $VarFile -Pattern '^\s*code\s*=' | ForEach-Object {
    if ($_.Line -match '=\s*"([^"]*)"') { $Matches[1] }
}

if (-not $ServiceCodes) {
    Write-Warn "No service codes found in $VarFile — nothing to import."
    exit 0
}

$script:Imported = 0
$script:Skipped  = 0
$script:NotFound = 0

# --- Helper: try to import a resource if it exists in Azure but not in state ---
function Invoke-TryImport {
    param([string]$TfAddress, [string]$AzureId)

    terraform state show $TfAddress *> $null
    if ($LASTEXITCODE -eq 0) {
        $script:Skipped++
        return
    }

    az rest --method GET --url "https://management.azure.com${AzureId}?api-version=2024-05-01" *> $null
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

foreach ($code in $ServiceCodes) {
    if (-not $code) { continue }

    $ProductId = "$code-$Postfix"
    $SubName   = "$code-$Postfix-SUB-01"

    # Product
    Invoke-TryImport `
        "azurerm_api_management_product.service[`"$code`"]" `
        "$ApimBaseId/products/$ProductId"

    # Product policy
    Invoke-TryImport `
        "azurerm_api_management_product_policy.service[`"$code`"]" `
        "$ApimBaseId/products/$ProductId/policies/policy"

    # Subscription
    Invoke-TryImport `
        "azurerm_api_management_subscription.service[`"$code`"]" `
        "$ApimBaseId/subscriptions/$SubName"

    # Product → API links (discover the APIs already attached to the product)
    $ProductApis = @()
    $apisJson = az rest --method GET `
        --url "https://management.azure.com$ApimBaseId/products/$ProductId/apis?api-version=2024-05-01" `
        2>$null | Out-String
    if ($apisJson.Trim()) {
        try {
            $parsed = $apisJson | ConvertFrom-Json
            foreach ($a in (Get-Prop $parsed 'value')) {
                $name = Get-Prop $a 'name'
                if ($name) { $ProductApis += $name }
            }
        } catch { }
    }

    foreach ($apiName in $ProductApis) {
        if (-not $apiName) { continue }
        Invoke-TryImport `
            "azurerm_api_management_product_api.service[`"$code-$apiName`"]" `
            "$ApimBaseId/products/$ProductId/apis/$apiName"
    }
}

# --- Summary ---
Write-Host ''
if ($script:Imported -gt 0) {
    Write-Success "Import complete: $($script:Imported) imported, $($script:Skipped) already in state, $($script:NotFound) not found in Azure."
}
else {
    Write-Info "No imports needed: $($script:Skipped) already in state, $($script:NotFound) not found in Azure."
}
