# CoreScope

Monitor local para macOS, com núcleo Rust e interface SwiftUI/AppKit. Métricas reais, histórico curto e controle manual de processos. Sem servidor, webview, telemetria ou otimizações automáticas.

## Compilar e abrir

Requisitos: macOS 14+, Command Line Tools com Swift e SDK macOS, Rust/Cargo. Build validado em macOS 27.0.1 arm64, Swift 6.4 e Rust 1.98.1; macOS 14 e Intel ainda precisam de validação física. A primeira compilação baixa as dependências Cargo; o aplicativo não usa rede.

```sh
git clone git@github.com:Tiagospem/corescope.git && cd corescope
./scripts/test.sh
./scripts/build.sh
open build/CoreScope.app
```

Saída: `build/CoreScope.app`. Assinatura **ad hoc**, sem Developer ID/notarização, destinada a este ambiente de desenvolvimento. Não altera SIP, não instala helper, não solicita root ou Full Disk Access. O build não instala nada em `/Applications`. Não copie o app enquanto o build estiver em execução.

## Uso

- **Visão geral**: CPU, memória, disco e rede com histórico; servidores em escuta (com botão para abrir `localhost`), possíveis órfãos, sessões de agentes, limites de uso e maiores consumidores — todos com encerramento direto.
- **Processos**: árvore por padrão (filhos de `launchd` viram raízes, totais Σ de CPU/memória por subárvore, ←/→ recolhe/expande), filtros Todos/Meus/Dev/Agentes/Servidores/Órfãos/Acompanhados, busca por nome, PID, porta, projeto ou agente. Colunas de projeto (cwd), origem (agente/editor/terminal) e portas. Painel de detalhes lateral (sem janelas modais).
- **Histórico** (opcional): 1 h, 24 h e 7 dias de CPU (média e pico), memória e swap, disco, rede, térmico e pressão; clique em um gráfico para ver os processos que dominaram aquele momento.
- **Agentes**: sessões do Claude Code (desktop e CLI) e Codex com título, estado (trabalhando/ociosa), projeto, processos iniciados, portas e encerramento da sessão inteira. Limite semanal do Codex lido dos eventos `rate_limits` que o próprio Codex grava em `~/.codex/sessions`. Limites de 5 horas e semanal do Claude Code (opcional, desligado por padrão, planos Pro/Max) vindos dos dados `rate_limits` que o próprio Claude Code passa ao [status line](https://code.claude.com/docs/en/statusline): ative em Ajustes › Agentes › “Ler limite do Claude pelo status line”. **Uso de tokens** contado das transcrições locais dos próprios agentes: entrada, saída e cache de prompt mais o modelo em cada sessão, e totais de hoje e dos últimos 7 dias por agente e por projeto. Só tokens, sem estimativas em dólar.
- **Projetos** (em construção, épico Projetos): cadastre repositórios locais escolhendo a pasta. O nome vem do `name:` do `.corescope.yml` (ou da pasta) e é editável; o `.corescope.yml` é validado com o mesmo parser do resto do app (erros com o número da linha) e a tela resume o que ele habilita (perfis, portas, serviços, logs, agentes). Sem `.corescope.yml`, o CoreScope oferece criar um mínimo — se você recusar, o projeto não é adicionado. Detecta repositório, worktree e repositório-pai; sem git, oferece `git init` com confirmação. Remover só tira da lista, nunca apaga arquivos. `corescope projects` e MCP `list_projects`.
- **Alterações e commit** (fase 2 do épico Projetos): *Alterações* no card abre um painel de commit no estilo do Zed/PhpStorm — branch com upstream e à frente/atrás, último commit e os arquivos em Conflitos, Staged, Modificados, Novos e Removidos/Renomeados, cada um com caminho, status e linhas +/−. O checkbox faz stage/unstage; seleção múltipla, *Stage em tudo* / *Unstage em tudo*; diff no estilo do Zed (sem seleção, todas as alterações desde o último commit empilhadas por arquivo, com cabeçalho fixo — checkbox de stage, nome, pasta, +/− e *Abrir* —, barra na margem verde/vermelha/amarela para adicionado/removido/modificado, números de linha, cores de sintaxe, trechos sem mudança recolhidos em "⋯ N linhas sem mudança" e ↑/↓ entre alterações); o card de cada repositório já mostra as contagens (staged, modificados, novos, removidos, conflitos, à frente/atrás) sem abrir nada, ao vivo com a página aberta; abrir no editor (Zed, Cursor, VS Code, JetBrains, Xcode…) ou no Finder. *Descartar alterações…* sempre pede confirmação: arquivos rastreados voltam ao último commit, arquivos novos vão para o Lixo. O botão Commit fica desabilitado sem mensagem, sem nada em stage ou com conflitos; ⌘↩ commita, hooks e assinatura rodam e a saída de um hook que falhou aparece como veio. `index.lock` vira um aviso, nunca um crash. Com o painel aberto, FSEvents (0,5 s) atualiza a lista, ignorando `.git` (exceto HEAD, index e refs) e o que o `.gitignore` cobre; o custo aparece em *Custo do próprio CoreScope* como *Projetos (git)*. `corescope status [PROJETO|PASTA]`, `corescope://project/NOME`, MCP `project_git_status` / `project_git_diff` / `project_git_stage` / `project_git_commit` / `project_git_discard`. 
- **Branches e worktrees** (fase 3): duas seções recolhíveis no card, fechadas por padrão (o git só roda quando uma é aberta). *Branches locais*: a atual primeiro, depois as mais recentes, com último commit, à frente/atrás do upstream, *em dia*, *upstream removido* ou *sem upstream*, e um aviso quando a branch está em outro worktree; mostra 12, *Mostrar todas* para o resto. *Worktrees*: todos os working trees do repositório, o principal primeiro — branch, agente que criou, mergeado na branch padrão, alterações, processo usando, `git worktree lock`, pasta sumiu, último commit e tamanho (medido em segundo plano, um por vez, com cache de 10 min; worktrees aninhados não contam duas vezes). Só visualização: a limpeza continua na página Limpeza, com link na seção. `corescope branches [PROJETO|PASTA]`, `corescope worktrees PROJETO`, MCP `project_branches` / `project_worktrees`. Próximas fases: painel e notificações, mensagem de commit com IA (opcional).
- **Agentes seguem o `.corescope.yml` sozinhos**: em *Ajustes › Servidor MCP › Hooks dos agentes*, para Claude Code e Codex, dois hooks opcionais (com backup do arquivo antes): *Contexto do projeto no início da sessão* (`corescope context --hook` resume o `.corescope.yml` mais próximo — regra de capacidade e comandos pesados, portas, perfis, serviços, logs, snapshot antes de apagar banco, ou o erro do arquivo com a linha) e *Esperar folga antes de comandos pesados* (`corescope gate`). O Codex só roda hooks depois que você confia neles em `/hooks`; a tela mostra se ele já confia. Agentes sem hooks recebem o mesmo texto pelo MCP `agent_context` ou por uma seção marcada no `CLAUDE.md` / `AGENTS.md` do projeto (*Instruções para agentes…* no card, `corescope context --write all`, MCP `write_agent_instructions`); o resto desses arquivos nunca é mexido. MCP `agent_hooks` consulta e muda os hooks.
- **Encerrar processos**: ✕ em qualquer linha (um clique arma, outro confirma), ⌫ / ⌘⌫ na tabela, menu de contexto, "Encerrar árvore" e "Forçar". Se o processo ignorar SIGTERM, o aviso oferece "Forçar encerramento". A confirmação de SIGTERM simples pode ser desligada em Ajustes.
- **Painel flutuante**: layouts compacto, padrão e detalhado; fixar acima das janelas, travar posição, tamanho, opacidade, rede e limites dos agentes direto no painel (botão ⋯ ou clique direito).
- **Barra de menus**: ícone + métricas escolhidas (CPU, memória, disco, rede, térmico, sensor, limites do Codex e do Claude opcionais); popover com gráficos de CPU, memória, disco e rede, órfãos, sessões, servidores e maior CPU.
- **Dock**: sempre, só com a janela aberta (padrão: ao fechar a janela o app fica só na barra de menus) ou nunca.
- **Idiomas**: português, inglês e espanhol; segue o idioma do sistema ou a escolha em Ajustes.
- **Cmd+1…7**: navegar. **Cmd+R**: atualizar. **Cmd+Shift+P**: painel. **Cmd+Shift+Espaço**: pausar/retomar.

O painel não ganha foco durante atualizações; é arrastável pelo fundo e salva posição por tela. Ao desconectar uma tela, tenta trazer o painel para uma área visível. Ajustes permitem recuperar a posição manualmente. O painel participa de Spaces/tela cheia; cenários físicos não exercitados estão explicitados no relatório.

## Definições e privacidade

Cada métrica traz unidade, origem, horário e disponibilidade no snapshot. Passe o mouse sobre a leitura para ver a fonte; o rodapé mostra a atualização, e pausa/falha sinaliza dados antigos. I/O tem cadência de 6 s, volumes de 30 s. Não há coleta em shell.

Memória principal = **ativa + wired + compressor físico**. Não equivale ao indicador “Memória usada” do Monitor de Atividade nem a “pressão”. O detalhe da memória segue as categorias do Monitor de Atividade: memória de apps (`internal − purgeable`), wired, comprimida, arquivos em cache (`external + purgeable`) e swap; pressão % = 100 − `kern.memorystatus_level`, ao lado dos eventos Dispatch. CPU por núcleo vem de `host_processor_info`, agrupada em P/E pelo `cluster-type` do IODeviceTree conferido com `hw.perflevel0/1`. Por processo usamos **phys_footprint**, com páginas residentes separadas nos detalhes. Pressão vem de eventos Dispatch: até receber o primeiro evento, permanece desconhecida. Swap ocupado não é diagnóstico por si só.

Argumentos e variáveis de ambiente **não são coletados**. Nomes, executáveis, UID, PID e início são lidos localmente. Gráficos ao vivo de até 120 pontos e 10 minutos, somente em RAM. O **histórico persistente é opcional** (desligado por padrão; Ajustes › Histórico, retenção de 1, 7 ou 30 dias): resumos de 1 minuto com CPU, memória, swap, taxas de disco/rede, térmico, pressão e os 10 processos com mais CPU e memória por minuto (nome, executável, diretório e origem; nunca argumentos ou ambiente), gravados em `~/Library/Application Support/CoreScope/history.sqlite` em uma transação por minuto. Dados além da retenção são apagados automaticamente; *Apagar histórico* remove o arquivo. Acompanhamentos/ignorados usam identidade PID + início e ficam no UserDefaults; não migram automaticamente para uma nova execução do mesmo programa. Não há exportador de argumentos ou log contínuo de processos.

Uso de tokens: lido somente ao abrir a página Agentes, em modo leitura, de `~/.claude/projects/<projeto>/<sessão>.jsonl` e `~/.claude/projects/<projeto>/<sessão>/subagents/*.jsonl` (objeto `usage` das entradas do assistente) e de `~/.codex/sessions/AAAA/MM/DD/*.jsonl` (eventos `token_count`). Só arquivos gravados nos últimos 7 dias e as transcrições de sessões em execução, cada um a partir de onde a leitura anterior parou. **O conteúdo das mensagens nunca é guardado:** as linhas passam por um buffer pequeno reutilizado e só ficam, em memória, contagens de tokens, ids de modelo e de sessão, diretórios de trabalho e o id da última mensagem vista em cada arquivo — nada é gravado em disco.

Limite do Claude Code (opcional): o Claude Code não grava o limite em disco, e o CoreScope nunca lê o Keychain, credenciais ou a rede para obtê-lo. Ao ligar a opção, o CoreScope faz backup de `~/.claude/settings.json` (em `~/Library/Application Support/CoreScope/backups/`) e adiciona um comando `statusLine` — só se não houver nenhum; um status line existente nunca é trocado, apenas encadeado se você pedir (o comando do CoreScope roda antes com `--record` e repassa a entrada, então a saída do seu continua igual). As demais chaves ficam como estavam. A cada resposta, o Claude Code passa o JSON do status line a `claude-statusline.sh`, que guarda **só** `rate_limits` em `claude-limits.json`. Desligar restaura o `statusLine` anterior (ou o mantém, se você o editou depois) e apaga os limites salvos e o script.

Possível órfão: processo seu, elegível, de runtime de desenvolvimento (node, python, php, bun, MCP…) fora de um app bundle, adotado pelo `launchd` há mais de 60 s — ou cuja mudança de pai foi observada. Confiança moderada: um serviço iniciado de propósito pode cumprir esses critérios. Nenhuma ação automática. O diretório de trabalho (cwd) e as portas TCP em escuta são lidos apenas de processos do próprio usuário, via `libproc`.

Contêineres: lidos da API do Docker Engine pelo socket Unix local (OrbStack, Docker Desktop, Colima, `/var/run/docker.sock` ou `DOCKER_HOST` `unix://`), nunca por TCP e sem credenciais. Lista e uma leitura `stats?one-shot=true` por contêiner em execução, no máximo a cada 5 s e só enquanto alguma vista de contêineres está na tela. CPU em % de um núcleo (delta entre leituras); memória sem cache de arquivos inativo, como `docker stats`. Parar/Reiniciar exigem dois cliques e usam `POST /containers/{id}/stop|restart?t=10`.

Encerramento: só usuário atual e processos elegíveis, com confirmação do executável e impacto. SIGTERM primeiro; SIGKILL é separado e avisa sobre perda de dados. Árvore usa lista fixa, filhos antes do pai, com revalidação de cada identidade. Não há `killall`, `pkill` ou sinalização de grupos. O macOS não oferece um identificador de processo atômico para `kill`: a revalidação reduz, mas não elimina matematicamente, a corrida residual de reutilização de PID.

## Organização

| Diretório | Responsabilidade |
|---|---|
| `core/src/containers.rs` | cliente local da API do Docker Engine (socket Unix), stats e parar/reiniciar |
| `core/src/lib.rs` | processamento Rust, diagnóstico, histórico, políticas de processo, FFI e testes |
| `core/src/os.rs` | tipos ABI e acesso seguro aos registros brutos |
| `core/src/macos.c` | adaptador mínimo para estruturas/API públicas do SDK |
| `native/` | modelos, serviço serial, SwiftUI, MenuBarExtra, NSPanel, agentes (`Agents.swift`) e traduções (`Localization.swift`) |
| `scripts/` | build, testes, ícone gerado (`make-icon.swift`) e medidor externo somente leitura |
| `docs/` | arquitetura, API, validação, consumo e investigação de sensores |
| `docs/screenshots/` | capturas do aplicativo (modo demo, dados anonimizados) |

Contrato de memória FFI em `native/CoreScopeFFI.h` e `docs/ARCHITECTURE.md`. A UI copia UTF-8 e sempre chama `cs_free`; Rust contém panics, e todo o estado é serializado. O adaptador C não toma decisões de diagnóstico.

## Evidências da entrega

[Funcionalidades e validação](VALIDATION.pt-BR.md) · [Consumo observado](CONSUMPTION.pt-BR.md) · [Investigação REA / Disk Drill](DISKDRILL-TEMPERATURE.pt-BR.md) · [Fontes das APIs](API-SOURCES.pt-BR.md) · [Capturas](screenshots/) · [Revisão visual](FINISH-REVIEW.pt-BR.md).
