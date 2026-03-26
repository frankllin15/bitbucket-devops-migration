# Instruções de Execução — Migração Bitbucket → Azure DevOps

## Visão Geral

A migração foi dividida em **dois scripts** para permitir validação por etapas:

| Script | O que faz | Altera algo? |
|---|---|---|
| `01-validar-repos-bitbucket.ps1` | Lista todos os repos do projeto no Bitbucket | Não — somente leitura |
| `02-migrar-bitbucket-azure.ps1` | Cria projeto/repos no Azure e faz o mirror completo | Sim (apenas no Azure, nunca no Bitbucket) |

---

## Pré-requisitos

| Requisito | Verificação |
|---|---|
| PowerShell 5.1 ou 7+ | `$PSVersionTable.PSVersion` |
| Git 2.x | `git --version` |
| Azure CLI 2.x | `az --version` |
| Extensão Azure DevOps CLI | `az extension list --query "[?name=='azure-devops']"` |

Instalar a extensão se necessário:
```powershell
az extension add --name azure-devops
```

> O script 02 verifica automaticamente se o Git e a extensão Azure DevOps estão instalados antes de prosseguir.

---

## Credenciais necessárias

### API Token do Bitbucket
Usado tanto para a API REST (listagem) quanto para o git clone.

1. Acesse **id.atlassian.com → Security → API tokens**
2. Clique em **Create API token**
3. Copie o token gerado

### PAT do Azure DevOps
Usado para criar projetos, repositórios e fazer o git push.

1. Acesse **Azure DevOps → User Settings (ícone de usuário) → Personal Access Tokens**
2. Clique em **New Token**
3. Escopo mínimo: **Code: Read & Write** e **Project and Team: Read, Write & Manage**
4. Copie o token gerado

---

## Etapa 1 — Validar repositórios do Bitbucket

### Objetivo
Confirmar que as credenciais estão corretas e ver a lista completa de repos **sem fazer nada no Azure**.

### Configurar o script `01-validar-repos-bitbucket.ps1`

```powershell
$bbWorkspace  = "delagerx"           # Workspace do Bitbucket
$bbProjectKey = "WMS"                # Key do projeto (ex: WMS, RX, ENP)
$bbEmail      = "seu@email.com"      # E-mail da conta Atlassian
$bbApiToken   = "seu_api_token"      # API Token gerado em id.atlassian.com
```

### Executar
```powershell
.\01-validar-repos-bitbucket.ps1
```

### Saída esperada
```
[ETAPA 1] Consultando repositórios no Bitbucket...
Workspace : delagerx
Projeto   : WMS

  Buscando página 1...

12 repositorio(s) encontrado(s):

    1. repo-alpha          [GIT]  https://bitbucket.org/delagerx/repo-alpha.git
    2. repo-beta           [GIT]  https://bitbucket.org/delagerx/repo-beta.git
    ...

[OK] Consulta concluida. Nenhuma alteracao foi feita.
```

---

## Etapa 2 — Migração completa para o Azure DevOps

Somente execute esta etapa após validar a listagem na Etapa 1.

### Configurar o script `02-migrar-bitbucket-azure.ps1`

```powershell
$bbWorkspace = "delagerx"
$bbProjectKey = "WMS"                        # Key do projeto no Bitbucket
$bbEmail     = "seu@email.com"               # E-mail Atlassian (usado na API REST)
$bbUser      = "seu_usuario_bitbucket"       # Username do Bitbucket (usado na URL git clone)
$bbApiToken  = "seu_api_token"               # API Token

$azOrgUrl    = "https://dev.azure.com/SuaOrganizacao"
$azPAT       = "seu_pat_azure"               # PAT do Azure DevOps
```

> **Nota:** `$azProjectName` é gerado automaticamente como `Bitbucket_<nome do projeto no Bitbucket>`. Não é necessário configurá-lo.

> **Nota:** `$bbUser` é o username do Bitbucket (visível na URL de clone), **não** o e-mail. Exemplo: se a URL de clone é `https://frankllinoliveira@bitbucket.org/...`, o username é `frankllinoliveira`.

### Executar
```powershell
.\02-migrar-bitbucket-azure.ps1
```

### Saída esperada
```
[0/3] Verificando pré-requisitos...
  git version 2.x.x
  Testando autenticação no Azure DevOps...
  Autenticação OK.

[1/3] Buscando repositorios no Bitbucket...
  Buscando página 1...
  Total: 12 repositorio(s) encontrado(s).
  Projeto Azure de destino: 'Bitbucket_WMS'

[2/3] Verificando projeto 'Bitbucket_WMS' no Azure DevOps...
  Projeto já existe (id: ...). Continuando...

[3/3] Iniciando migração...

>>> [1/12] repo-alpha
  Verificando se repositorio já existe no Azure...
  Criando repositorio no Azure...
  Clonando do Bitbucket...
  Enviando para o Azure DevOps...
  Concluído!
...

=============================================
 MIGRAÇÃO CONCLUÍDA
=============================================
  Sucessos : 12
  Ignorados: 0 (já existiam no Azure)
  Falhas   : 0
```

---

## Comportamento de segurança

O script 02 foi projetado para ser **cauteloso e idempotente**:

| Situação | Comportamento |
|---|---|
| Repositório já existe no Azure (com ou sem commits) | **Ignorado** — nunca sobrescreve |
| Projeto já existe no Azure | Reutiliza o existente |
| Falha ao criar repositório | Registra o erro e **pula** para o próximo |
| Falha no git clone ou push | Registra o erro, limpa a pasta temporária e pula |
| Script abortado com Ctrl+C | Limpa pasta temporária automaticamente via `trap` |
| Credenciais em mensagens de erro | Substituídas por `***` antes de exibir |

> O Bitbucket **nunca é alterado** — todas as operações são de leitura (API GET e git clone).

---

## Múltiplos projetos

Para migrar mais de um projeto Bitbucket, execute o script uma vez por projeto alterando apenas a variável `$bbProjectKey`:

```powershell
$bbProjectKey = "RX"    # O nome do projeto Azure será gerado automaticamente
```

---

## O que é migrado

| Item | Migrado? |
|---|---|
| Branches | Sim (via `--mirror`) |
| Tags | Sim (via `--mirror`) |
| Histórico de commits | Sim |
| Pull Requests | Não |
| Issues / Comentários | Não |
| Permissões de acesso | Não |
| Pipelines / CI | Não |

---

## Solução de Problemas

| Sintoma | Causa | Solução |
|---|---|---|
| Erro 401 na API do Bitbucket | API Token inválido ou expirado | Gere novo API Token em id.atlassian.com |
| `git clone` falha com 128 | Username do Bitbucket incorreto ou token sem permissão | Verifique `$bbUser` (deve ser o username, não o e-mail) |
| Extensão azure-devops não encontrada | Extensão não instalada | `az extension add --name azure-devops` |
| Falha de autenticação no Azure DevOps | PAT ausente, expirado ou sem escopo | Gere novo PAT com `Code: Read & Write` e `Project: Read, Write & Manage` |
| Caracteres acentuados corrompidos | Arquivo .ps1 não está em UTF-8 com BOM | Salve o arquivo com encoding "UTF-8 with BOM" no editor |
| Pasta `temp_migrate_*` restante | Script interrompido de forma abrupta | `Remove-Item -Recurse -Force temp_migrate_*` |
| Nenhum repo encontrado | Project Key incorreta | Confirme a key no Bitbucket em **Project Settings** |
| Erro de URL com "Port number" | E-mail usado no lugar do username na URL git | Use `$bbUser` (sem `@`) em vez de `$bbEmail` |
