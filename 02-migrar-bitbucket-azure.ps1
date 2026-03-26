# =============================================================================
# ETAPA 2 — Migração completa: Bitbucket → Azure DevOps
# Pré-requisito: rode o script 01-validar-repos-bitbucket.ps1 primeiro.
# =============================================================================

# Força UTF-8 no terminal e no PowerShell para exibir caracteres especiais corretamente
$null = cmd /c "chcp 65001" 2>$null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# --- CONFIGURAÇÕES ---
$bbWorkspace   = "delagerx"
$bbProjectKey  = "WMS"                       # Key do projeto no Bitbucket (ex: WMS, RX, etc)
$bbEmail       = "frankllin.oliveira@delage.com.br"     # E-mail da conta Atlassian (usado na API REST)
$bbUser        = "frankllinoliveira"                    # Username do Bitbucket (usado na URL git clone)
$bbApiToken    = ""             # API Token gerado em id.atlassian.com

$azOrgUrl      = "https://dev.azure.com/delagesistemas"
$azPAT         = ""     # Personal Access Token do Azure (Code: Read & Write)
# $azProjectName é gerado automaticamente após buscar os repos: "Bitbucket_<nome do projeto no Bitbucket>"

# =============================================================================

# Garante diretório base para pastas temporárias
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Limpa pasta temporária caso o script seja abortado com Ctrl+C
$tempFolderAtual = $null
$pushLocationAtivo = $false

trap {
    if ($pushLocationAtivo) { Pop-Location }
    if ($tempFolderAtual -and (Test-Path $tempFolderAtual)) {
        Remove-Item -Recurse -Force $tempFolderAtual
    }
    break
}

# Função auxiliar para limpar credenciais de mensagens de erro
function Remove-Credentials {
    param([string]$Text)
    $Text = $Text -replace [regex]::Escape($bbApiToken), '***'
    $Text = $Text -replace [regex]::Escape($azPAT), '***'
    return $Text
}

# --- PRÉ-VERIFICAÇÃO: autenticação e dependências ---
Write-Host "`n[0/3] Verificando pré-requisitos..." -ForegroundColor Cyan

# Verifica se git está instalado
$gitVersion = git --version 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO FATAL] Git não encontrado. Instale o Git antes de executar este script." -ForegroundColor Red
    exit 1
}
Write-Host "  $gitVersion" -ForegroundColor DarkGray

# Injeta o PAT como variável de ambiente reconhecida pelo az devops CLI
$env:AZURE_DEVOPS_EXT_PAT = $azPAT

# Verifica se az devops está instalado
$azDevopsExt = az extension list --query "[?name=='azure-devops'].name" --output tsv 2>$null
if (-not $azDevopsExt) {
    Write-Host "[ERRO FATAL] Extensão 'azure-devops' não instalada no Azure CLI." -ForegroundColor Red
    Write-Host "  Execute: az extension add --name azure-devops" -ForegroundColor Yellow
    exit 1
}

# Valida que o PAT consegue autenticar na organização
Write-Host "  Testando autenticação no Azure DevOps..." -ForegroundColor Gray
$authTest = az devops project list --organization "$azOrgUrl" --output json 2>&1
$authJson = try { $authTest | ConvertFrom-Json } catch { $null }
if ($LASTEXITCODE -ne 0 -or $null -eq $authJson) {
    Write-Host "[ERRO FATAL] Falha de autenticação no Azure DevOps." -ForegroundColor Red
    Write-Host "  Verifique se o PAT é válido e tem permissão 'Code: Read & Write' e 'Project: Read & Write'." -ForegroundColor Yellow
    Write-Host "  Detalhe: $(Remove-Credentials $authTest)" -ForegroundColor Red
    exit 1
}
Write-Host "  Autenticação OK." -ForegroundColor Green

# --- 1. BUSCAR REPOSITÓRIOS DO BITBUCKET (COM PAGINAÇÃO) ---
Write-Host "`n[1/3] Buscando repositorios no Bitbucket..." -ForegroundColor Cyan

$bbAuth  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${bbEmail}:${bbApiToken}"))
$headers = @{ Authorization = "Basic $bbAuth" }

$repos   = @()
$apiUrl  = "https://api.bitbucket.org/2.0/repositories/$($bbWorkspace)?q=project.key=`"$($bbProjectKey)`"&pagelen=100"
$pagina  = 1

do {
    Write-Host "  Buscando página $pagina..." -ForegroundColor DarkGray
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
    }
    catch {
        Write-Host "`n[ERRO] Falha na API do Bitbucket: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    $repos  += $response.values
    $apiUrl  = $response.next
    $pagina++
} while ($apiUrl)

if ($repos.Count -eq 0) {
    Write-Host "[ERRO FATAL] Nenhum repositorio encontrado para o projeto '$bbProjectKey'. Verifique a Project Key." -ForegroundColor Red
    exit 1
}

# Gera o nome do projeto Azure a partir do nome do projeto Bitbucket
$bbProjectName = $repos[0].project.name
$azProjectName = "Bitbucket_$bbProjectName"
Write-Host "  Total: $($repos.Count) repositorio(s) encontrado(s)." -ForegroundColor Magenta
Write-Host "  Projeto Azure de destino: '$azProjectName'" -ForegroundColor DarkGray

# --- 2. GARANTIR QUE O PROJETO EXISTE NO AZURE ---
Write-Host "`n[2/3] Verificando projeto '$azProjectName' no Azure DevOps..." -ForegroundColor Cyan

$projectJson = az devops project show `
    --project "$azProjectName" `
    --organization "$azOrgUrl" `
    --output json 2>$null

$projectCheck = if ($projectJson) { try { $projectJson | ConvertFrom-Json } catch { $null } } else { $null }

if ($null -eq $projectCheck -or $null -eq $projectCheck.id) {
    Write-Host "  Projeto não encontrado. Criando '$azProjectName'..." -ForegroundColor Yellow
    $createJson = az devops project create `
        --name "$azProjectName" `
        --organization "$azOrgUrl" `
        --visibility private `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERRO FATAL] Falha ao criar o projeto no Azure DevOps. Abortando." -ForegroundColor Red
        Write-Host "  Detalhe: $(Remove-Credentials $createJson)" -ForegroundColor Red
        exit 1
    }

    $createResult = try { $createJson | ConvertFrom-Json } catch { $null }
    if ($null -eq $createResult -or $null -eq $createResult.id) {
        Write-Host "[ERRO FATAL] Projeto criado mas resposta inesperada. Abortando." -ForegroundColor Red
        Write-Host "  Detalhe: $(Remove-Credentials $createJson)" -ForegroundColor Red
        exit 1
    }

    Write-Host "  Projeto criado (id: $($createResult.id)). Aguardando provisionamento..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
} else {
    Write-Host "  Projeto já existe (id: $($projectCheck.id)). Continuando..." -ForegroundColor Green
}

# --- 3. LOOP DE CRIAÇÃO E MIGRAÇÃO ---
Write-Host "`n[3/3] Iniciando migração..." -ForegroundColor Cyan

$sucessos  = 0
$falhas    = 0
$ignorados = 0
$erros     = @()
$indice    = 0
$azProjectEncoded = [Uri]::EscapeDataString($azProjectName)

foreach ($repo in $repos) {
    $indice++
    $name       = $repo.slug
    $tempFolder = Join-Path $scriptDir "temp_migrate_$name"

    Write-Host "`n>>> [$indice/$($repos.Count)] $name" -ForegroundColor White -BackgroundColor DarkBlue

    # --- GUARDA DE SEGURANÇA: verificar se o repo já existe no Azure ---
    Write-Host "  Verificando se repositorio já existe no Azure..." -ForegroundColor Gray
    $azRepoJson = az repos show `
        --repository "$name" `
        --project "$azProjectName" `
        --organization "$azOrgUrl" `
        --output json 2>$null

    if ($azRepoJson) {
        $azRepo = try { $azRepoJson | ConvertFrom-Json } catch { $null }
        if ($azRepo) {
            if ($azRepo.size -gt 0) {
                Write-Host "  [IGNORADO] Repositorio já existe no Azure e contém commits. Pulando para evitar sobrescrita." -ForegroundColor Yellow
            } else {
                Write-Host "  [IGNORADO] Repositorio já existe no Azure (vazio). Pulando para evitar sobrescrita." -ForegroundColor Yellow
            }
            $ignorados++
            continue
        }
    }

    # Criar repositorio no Azure
    Write-Host "  Criando repositorio no Azure..." -ForegroundColor Gray
    $createRepoJson = az repos create `
        --name "$name" `
        --project "$azProjectName" `
        --organization "$azOrgUrl" `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERRO] Falha ao criar repositorio '$name' no Azure. Pulando." -ForegroundColor Red
        $erros += [PSCustomObject]@{ Repo = $name; Erro = "az repos create falhou: $(Remove-Credentials $createRepoJson)" }
        $falhas++
        continue
    }

    $bbUrl = "https://${bbUser}:${bbApiToken}@bitbucket.org/$bbWorkspace/$name.git"
    $azUrl = "https://oauth2:${azPAT}@dev.azure.com/$(($azOrgUrl -split '/')[-1])/$azProjectEncoded/_git/$name"

    $pushLocationAtivo = $false
    $tempFolderAtual = $tempFolder
    try {
        # Clone espelho do Bitbucket
        Write-Host "  Clonando do Bitbucket..." -ForegroundColor Gray
        $cloneOutput = git clone --mirror $bbUrl $tempFolder 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git clone falhou com codigo $LASTEXITCODE`n    $(Remove-Credentials ($cloneOutput -join "`n    "))" }

        Push-Location $tempFolder
        $pushLocationAtivo = $true

        # Push espelho para o Azure DevOps
        Write-Host "  Enviando para o Azure DevOps..." -ForegroundColor Gray
        git remote add azure $azUrl
        $pushOutput = git push azure --mirror 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git push falhou com codigo $LASTEXITCODE`n    $(Remove-Credentials ($pushOutput -join "`n    "))" }

        Pop-Location
        $pushLocationAtivo = $false
        Remove-Item -Recurse -Force $tempFolder
        $tempFolderAtual = $null
        Write-Host "  Concluído!" -ForegroundColor Green
        $sucessos++
    }
    catch {
        $msg = $_.Exception.Message
        Write-Host "  [ERRO] $msg" -ForegroundColor Red
        $erros += [PSCustomObject]@{ Repo = $name; Erro = $msg }
        $falhas++

        if ($pushLocationAtivo) { Pop-Location; $pushLocationAtivo = $false }
        if (Test-Path $tempFolder) { Remove-Item -Recurse -Force $tempFolder }
        $tempFolderAtual = $null
    }
}

# --- RELATÓRIO FINAL ---
Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host " MIGRAÇÃO CONCLUÍDA" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Sucessos : $sucessos" -ForegroundColor Green
Write-Host "  Ignorados: $ignorados (já existiam no Azure)" -ForegroundColor Yellow
Write-Host "  Falhas   : $falhas" -ForegroundColor $(if ($falhas -gt 0) { "Red" } else { "Green" })

if ($erros.Count -gt 0) {
    Write-Host "`n  Repositorios com erro:" -ForegroundColor Red
    $erros | ForEach-Object { Write-Host "    - $($_.Repo): $($_.Erro)" -ForegroundColor Red }
}

Write-Host ""
