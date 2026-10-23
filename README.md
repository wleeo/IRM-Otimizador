# IRM Otimizador

Ferramenta de manutenção, performance e configuração para **Windows 10 / 11** — para uso em suporte/cloud a host.
Menu interativo, tudo **reversível** (backup automático + `Restore-IRM.ps1`).

## Como rodar (máquina alvo)

```powershell
# Versão estável (última release publicada)
irm https://github.com/wleeo/IRM-Otimizador/releases/latest/download/otimizar.ps1 | iex

# Versão dev (branch main — para testar mudanças novas)
irm https://raw.githubusercontent.com/wleeo/IRM-Otimizador/main/otimizar.ps1 | iex
```

Requer: PowerShell 5.1+ · Executar como administrador (o script se auto-eleva sozinho).

## O que faz

| Opção | Categoria |
|---|---|
| [1] | Energia & CPU — Desempenho Final (AC/DC no notebook), hibernação, `numproc` no boot (pula máquina Entra/AzureAD) |
| [2] | Jogos & GPU — GameDVR off, HAGS, prioridade foreground, anti-Nagle, telemetria NVIDIA |
| [3] | Inicialização & Visual — limpeza interativa de startup, Edge boost, preset de efeitos visuais |
| [4] | Limpeza & Disco — temp/lixeira/cache, Storage Sense, DISM WinSxS, tarefas de manutenção, TRIM/defrag, SFC |
| [5] | Privacidade & Bloat — telemetria mínima, widgets/ads, remoção de bloatware com lista |
| [6] | Suite ASUS (diet) — Armoury Crate/Aura/ROG (preserva Fan Xpert) |
| [7] | Programas — catálogo de instalação (Chrome, AnyDesk, Aker, OneDrive, Office 365 via ODT, Teams, Store apps) |
| [8] | Relatórios — saúde dos discos (com temperatura), libs Steam, pendências |
| [R] | Rede & DNS — Cloudflare/Google/Quad9 + Delivery Optimization local |
| [9] | RESTAURAR — desfaz tudo (registry, serviços, plano, rede, tarefas) |
| [0] | Aplicar TUDO — rotina completa |

## Segurança

- Antes de cada alteração: export do trecho de registry em `%USERPROFILE%\IRM-Backup`
- `manifest.json` registra serviços/plano/tarefas/flags → gera `Restore-IRM.ps1` autônomo
- Detecção Win10 vs Win11: adapta os itens (HAGS, widgets, plano Ultimate)

## Fluxo de versão

1. Editar `otimizar.ps1` (atualizar `$ScriptVersion` no topo)
2. `git commit` + `git push` → URL dev já vale em minutos
3. Publicar estável: `git tag v1.2.0 && git push origin v1.2.0` + criar a Release no GitHub
4. Binários grandes (ex: instalador Aker) ficam no **bucket R2** (`irm.abysm.com.br/aker/...`), nunca no git
