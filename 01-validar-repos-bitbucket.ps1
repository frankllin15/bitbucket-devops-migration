# Força UTF-8 no terminal e no PowerShell para exibir caracteres especiais corretamente
# $null = cmd /c "chcp 65001" 2>$null
# [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
# $OutputEncoding           = [System.Text.Encoding]::UTF8
# =============================================================================
# ETAPA 1 — Consulta e listagem de repositórios do Bitbucket
# Objetivo: Validar credenciais e listar os repos ANTES de qualquer migração.
# Não cria nada no Azure. Não clona nada. Apenas lê e exibe.
# =============================================================================

# --- CONFIGURAÇÕES ---
$bbWorkspace  = "delagerx"
$bbProjectKey = "ES"              # Key do projeto no Bitbucket (ex: WMS, RX, etc)
$bbEmail      = "frankllin.oliveira@delage.com.br"  # E-mail da conta Atlassian
$bbApiToken   = "" # API Token gerado em id.atlassian.com

# --- AUTENTICAÇÃO ---
$bbAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${bbEmail}:${bbApiToken}"))
$headers = @{ Authorization = "Basic $bbAuth" }

# --- BUSCA COM PAGINAÇÃO COMPLETA ---
Write-Host "`n[ETAPA 1] Consultando repositórios no Bitbucket..." -ForegroundColor Cyan
Write-Host "Workspace : $bbWorkspace" -ForegroundColor Gray
Write-Host "Projeto   : $bbProjectKey`n" -ForegroundColor Gray

$repos   = @()
$apiUrl  = "https://api.bitbucket.org/2.0/repositories/$($bbWorkspace)?q=project.key=`"$($bbProjectKey)`"&pagelen=100"
$pagina  = 1

do {
    Write-Host "  Buscando pagina $pagina..." -ForegroundColor DarkGray
    Write-Host "  URL: $apiUrl" -ForegroundColor DarkGray
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
    }
    catch {
        Write-Host "`n[ERRO] Falha na chamada a API do Bitbucket." -ForegroundColor Red
        Write-Host "  Mensagem : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Verifique: e-mail, API Token e permissao 'Repositories: Read'." -ForegroundColor Yellow
        exit 1
    }

    $repos  += $response.values
    $apiUrl  = $response.next
    $pagina++
} while ($apiUrl)

# --- RESULTADO ---
if ($repos.Count -eq 0) {
    Write-Host "`n[AVISO] Nenhum repositorio encontrado para o projeto '$bbProjectKey'." -ForegroundColor Yellow
    Write-Host "  Verifique se a Project Key esta correta." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n$($repos.Count) repositorio(s) encontrado(s):`n" -ForegroundColor Magenta

$i = 1
foreach ($repo in $repos) {
    Write-Host ("  {0,3}. {1,-40}  [{2}]  {3}" -f `
        $i, $repo.slug, $repo.scm.ToUpper(), $repo.links.clone[0].href) -ForegroundColor White
    $i++
}

Write-Host "`n[OK] Consulta concluida. Nenhuma alteracao foi feita." -ForegroundColor Green
Write-Host "     Execute o proximo script quando estiver pronto para migrar.`n" -ForegroundColor Green