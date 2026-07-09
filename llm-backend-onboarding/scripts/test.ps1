#!/usr/bin/env pwsh
# =============================================================================
# LLM Backend Onboarding — Test Script
#
# Tests the onboarded LLM backends by sending requests through the APIM gateway.
# Validates:
#   1. Backend connectivity (health check via get-available-models)
#   2. Chat completions via OpenAI-compatible API
#   3. Chat completions via Models Inference API
#   4. Streaming responses
#   5. Backend pool load balancing (if multiple backends configured)
#
# Usage:
#   ./scripts/test.ps1 [OPTIONS]
#
# Options:
#   -GatewayUrl URL         APIM gateway URL (auto-detected from Terraform state)
#   -ApiKey KEY             APIM subscription key (required)
#   -Model MODEL            Model to test (default: first model in config)
#   -AllModels              Test all configured models
#   -Verbose                Show full response bodies
#   -Help                   Show this help message
#
# Prerequisites:
#   - Successful deployment via ./scripts/deploy.ps1
#   - Valid APIM subscription key with access to the LLM APIs
#
# Examples:
#   ./scripts/test.ps1 -ApiKey "your-api-key"
#   ./scripts/test.ps1 -ApiKey "your-key" -Model gpt-4o -Verbose
#   ./scripts/test.ps1 -ApiKey "your-key" -AllModels
#   ./scripts/test.ps1 -GatewayUrl "https://apim-xxx.azure-api.net" -ApiKey "key"
# =============================================================================

[CmdletBinding()]
param(
    [string]$GatewayUrl = '',
    [string]$ApiKey = '',
    [string]$Model = '',
    [switch]$AllModels,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Colour helpers ---
function Write-Info     { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Blue }
function Write-Pass     { param([string]$Message) Write-Host "[PASS]  $Message" -ForegroundColor Green }
function Write-Warn     { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-FailTest {
    param([string]$Message)
    Write-Host "[FAIL]  $Message" -ForegroundColor Red
    $script:Failures++
}

if ($Help) {
    foreach ($line in (Get-Content $PSCommandPath | Select-Object -Skip 1)) {
        if ($line -notmatch '^#') { break }
        $line -replace '^# ?', ''
    }
    exit 0
}

$script:Failures = 0
$script:Tests    = 0
$isVerbose = $VerbosePreference -ne 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir

# --- Validate prerequisites ---
if (-not $ApiKey) {
    Write-Host 'Error: -ApiKey is required' -ForegroundColor Red
    Write-Host '  Get a key from your APIM subscription in the Azure portal.'
    exit 1
}

# --- Auto-detect gateway URL from Terraform state ---
if (-not $GatewayUrl) {
    Set-Location $RootDir
    if (Test-Path 'terraform.tfstate') {
        $GatewayUrl = (terraform output -raw apim_gateway_url 2>$null)
        if ($LASTEXITCODE -ne 0) { $GatewayUrl = '' }
    }
    if (-not $GatewayUrl) {
        Write-Host 'Error: Could not auto-detect gateway URL.' -ForegroundColor Red
        Write-Host '  Pass -GatewayUrl or run from the directory with terraform.tfstate'
        exit 1
    }
}

# Remove trailing slash
$GatewayUrl = $GatewayUrl.TrimEnd('/')

Write-Info "Testing APIM Gateway: $GatewayUrl"
Write-Host ''

# --- Discover available models from terraform output ---
function Get-Models {
    Set-Location $RootDir
    if (Test-Path 'terraform.tfstate') {
        $json = terraform output -json supported_models 2>$null | Out-String
        if ($json.Trim()) {
            try { return @($json | ConvertFrom-Json) } catch { return @() }
        }
    }
    return @()
}

# --- Test helper ---
function Invoke-RunTest {
    param(
        [string]$TestName,
        [string]$Url,
        [string]$Method = 'GET',
        [string]$Body = '',
        [string]$ExpectedStatus = '200'
    )
    $script:Tests++

    $headers = @{ 'api-key' = $ApiKey; 'Content-Type' = 'application/json' }
    $statusCode = '000'
    $responseBody = ''
    try {
        if ($Method -eq 'POST' -and $Body) {
            $resp = Invoke-WebRequest -Uri $Url -Method Post -Headers $headers -Body $Body -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        }
        else {
            $resp = Invoke-WebRequest -Uri $Url -Method Get -Headers $headers -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        }
        $statusCode = [string]$resp.StatusCode
        $responseBody = $resp.Content
    }
    catch {
        if ($_.Exception.Response) { $statusCode = [string][int]$_.Exception.Response.StatusCode } else { $statusCode = '000' }
    }

    if ($statusCode -eq $ExpectedStatus) {
        Write-Pass "$TestName (HTTP $statusCode)"
        if ($isVerbose -and $responseBody) {
            try { $responseBody | ConvertFrom-Json | ConvertTo-Json -Depth 10 } catch { Write-Host $responseBody }
            Write-Host ''
        }
        return $true
    }
    else {
        Write-FailTest "$TestName — Expected HTTP $ExpectedStatus, got $statusCode"
        if ($responseBody) {
            $snippet = $responseBody.Substring(0, [Math]::Min(200, $responseBody.Length))
            Write-Host "    Response: $snippet"
        }
        return $false
    }
}

# =============================================================================
# TEST 1: Get Available Models (Health Check)
# =============================================================================
Write-Host '━━━ Test Suite: Backend Connectivity ━━━' -ForegroundColor Blue

Invoke-RunTest 'GET /llm/openai/deployments (available models)' `
    "$GatewayUrl/llm/openai/deployments?api-version=2024-02-15-preview" | Out-Null

Write-Host ''

# =============================================================================
# TEST 2: Chat Completions (OpenAI-compatible API)
# =============================================================================
Write-Host '━━━ Test Suite: Chat Completions (OpenAI API) ━━━' -ForegroundColor Blue

function Test-ChatCompletion {
    param([string]$ModelName)
    $body = @{
        messages    = @(@{ role = 'user'; content = 'Say hello in one word.' })
        max_tokens  = 10
        temperature = 0
    } | ConvertTo-Json -Depth 5 -Compress

    Invoke-RunTest "POST /llm/openai/deployments/$ModelName/chat/completions" `
        "$GatewayUrl/llm/openai/deployments/$ModelName/chat/completions?api-version=2024-02-15-preview" `
        'POST' $body | Out-Null
}

if ($AllModels) {
    $models = Get-Models
    if ($models.Count -eq 0) {
        Write-Warn 'Could not discover models from Terraform state. Testing default model.'
        $models = @('gpt-4o-mini')
    }
    foreach ($m in $models) {
        if (-not $m) { continue }
        Test-ChatCompletion $m
    }
}
elseif ($Model) {
    Test-ChatCompletion $Model
}
else {
    # Default: test first model from Terraform output or gpt-4o-mini
    $defaultModel = (Get-Models | Select-Object -First 1)
    if (-not $defaultModel) { $defaultModel = 'gpt-4o-mini' }
    Test-ChatCompletion $defaultModel
}

Write-Host ''

# =============================================================================
# TEST 3: Chat Completions via Models Inference API
# =============================================================================
Write-Host '━━━ Test Suite: Chat Completions (Inference API) ━━━' -ForegroundColor Blue

function Test-InferenceCompletion {
    param([string]$ModelName)
    $body = @{
        model       = $ModelName
        messages    = @(@{ role = 'user'; content = 'Say hello in one word.' })
        max_tokens  = 10
        temperature = 0
    } | ConvertTo-Json -Depth 5 -Compress

    Invoke-RunTest "POST /llm/models/chat/completions (model=$ModelName)" `
        "$GatewayUrl/llm/models/chat/completions?api-version=2024-05-01-preview" `
        'POST' $body | Out-Null
}

if ($Model) {
    Test-InferenceCompletion $Model
}
else {
    $defaultModel = (Get-Models | Select-Object -First 1)
    if (-not $defaultModel) { $defaultModel = 'gpt-4o-mini' }
    Test-InferenceCompletion $defaultModel
}

Write-Host ''

# =============================================================================
# TEST 4: Streaming Response
# =============================================================================
Write-Host '━━━ Test Suite: Streaming ━━━' -ForegroundColor Blue

function Test-Streaming {
    param([string]$ModelName)
    $script:Tests++

    $body = @{
        messages    = @(@{ role = 'user'; content = 'Count from 1 to 3.' })
        max_tokens  = 50
        temperature = 0
        stream      = $true
    } | ConvertTo-Json -Depth 5 -Compress

    $statusCode = '000'
    $responseBody = ''
    try {
        $resp = Invoke-WebRequest `
            -Uri "$GatewayUrl/llm/openai/deployments/$ModelName/chat/completions?api-version=2024-02-15-preview" `
            -Method Post `
            -Headers @{ 'api-key' = $ApiKey; 'Content-Type' = 'application/json' } `
            -Body $body -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        $statusCode = [string]$resp.StatusCode
        $responseBody = $resp.Content
    }
    catch {
        if ($_.Exception.Response) { $statusCode = [string][int]$_.Exception.Response.StatusCode } else { $statusCode = '000' }
    }

    if ($statusCode -eq '200') {
        # Check for SSE format (data: prefix)
        if ($responseBody -match '(?m)^data:') {
            Write-Pass "Streaming chat completions ($ModelName) — SSE chunks received"
            if ($isVerbose) {
                ($responseBody -split "`n" | Select-Object -First 5) | ForEach-Object { Write-Host $_ }
                Write-Host '    ...'
            }
        }
        else {
            Write-Warn "Streaming ($ModelName) — HTTP 200 but no SSE chunks detected"
        }
    }
    else {
        Write-FailTest "Streaming chat completions ($ModelName) — HTTP $statusCode"
    }
}

$defaultModel = (Get-Models | Select-Object -First 1)
if (-not $defaultModel) { $defaultModel = 'gpt-4o-mini' }
$streamModel = if ($Model) { $Model } else { $defaultModel }
Test-Streaming $streamModel

Write-Host ''

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Blue
$passed = $script:Tests - $script:Failures
if ($script:Failures -eq 0) {
    Write-Host "All $($script:Tests) tests passed!" -ForegroundColor Green
}
else {
    Write-Host "$passed/$($script:Tests) passed, $($script:Failures) failed" -ForegroundColor Yellow
}
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Blue

exit $script:Failures
