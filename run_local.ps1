param(
    [string]$AdminUser = "admin",
    [string]$AdminPassword = "jerryin2323",
    [string]$AdminToken = "phase11-admin-token",
    [string]$SessionSecret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    [string]$SessionTokenPepper = "dev_session_token_pepper_0123456789abcdef0123456789ab",
    [string]$AuthPepper = "dev_auth_pepper_0123456789abcdef",
    [switch]$StartDockerDb,
    [string]$PostgresPassword = "change_me",
    [switch]$OpenDashboard = $true
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

if ($StartDockerDb) {
    Write-Host "[BioKey] Starting PostgreSQL via docker compose..." -ForegroundColor Cyan
    Push-Location (Join-Path $repoRoot "database")
    $env:POSTGRES_PASSWORD = $PostgresPassword
    docker compose up -d
    Pop-Location
}

Write-Host "[BioKey] Preparing backend environment..." -ForegroundColor Cyan
$env:ADMIN_USER = $AdminUser
$env:APP_SESSION_SECRET = $SessionSecret
$env:SESSION_TOKEN_PEPPER = $SessionTokenPepper
$env:APP_AUTH_PEPPER = $AuthPepper
$env:ENABLE_ASYNC_ADMIN_JOBS = "false"
$env:BIOKEY_ADMIN_PASSWORD = $AdminPassword
$env:BIOKEY_ADMIN_TOKEN = $AdminToken

$adminHash = ruby -rbcrypt -e "puts BCrypt::Password.create(ENV['BIOKEY_ADMIN_PASSWORD'])"
$env:ADMIN_PASSWORD_HASH = $adminHash.Trim()

$adminTokenHash = ruby -rdigest -e "puts Digest::SHA256.hexdigest(ENV['BIOKEY_ADMIN_TOKEN'])"
$env:ADMIN_TOKEN_HASH = $adminTokenHash.Trim()
Remove-Item Env:BIOKEY_ADMIN_PASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:BIOKEY_ADMIN_TOKEN -ErrorAction SilentlyContinue

Push-Location (Join-Path $repoRoot "backend-server")

Write-Host "[BioKey] Installing Ruby gems (bundle install)..." -ForegroundColor Cyan
bundle install

Write-Host "[BioKey] Running migrations..." -ForegroundColor Cyan
ruby db/migrate.rb

if ($OpenDashboard) {
    Write-Host "[BioKey] Opening dashboard in your default browser..." -ForegroundColor Cyan
    Start-Job -Name "biokey-dashboard-open" -ScriptBlock {
        Start-Sleep -Seconds 3
        Start-Process "http://127.0.0.1:4567/admin"
    } | Out-Null
}

Write-Host "[BioKey] Starting backend on http://127.0.0.1:4567 ..." -ForegroundColor Green
Write-Host "[BioKey] Dashboard: http://127.0.0.1:4567/admin" -ForegroundColor Green
Write-Host "[BioKey] Admin login: $AdminUser / $AdminPassword" -ForegroundColor Yellow

ruby app.rb

Pop-Location
