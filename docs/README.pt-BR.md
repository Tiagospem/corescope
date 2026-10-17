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
- **Agentes**: sessões do Claude Code (desktop e CLI) e Codex com título, estado (trabalhando/ociosa), projeto, processos iniciados, portas e encerramento da sessão inteira. Limite semanal do Codex lido dos eventos `rate_limits` que o próprio Codex grava em `~/.codex/sessions`. O Claude Code não grava o limite semanal em disco; o CoreScope não lê credenciais nem acessa a rede para obtê-lo. **Uso de tokens** contado das transcrições locais dos próprios agentes: entrada, saída e cache de prompt mais o modelo em cada sessão, e totais de hoje e dos últimos 7 dias por agente e por projeto. Só tokens, sem estimativas em dólar.
- **Encerrar processos**: ✕ em qualquer linha (um clique arma, outro confirma), ⌫ / ⌘⌫ na tabela, menu de contexto, "Encerrar árvore" e "Forçar". Se o processo ignorar SIGTERM, o aviso oferece "Forçar encerramento". A confirmação de SIGTERM simples pode ser desligada em Ajustes.
- **Painel flutuante**: layouts compacto, padrão e detalhado; fixar acima das janelas, travar posição, tamanho, opacidade, rede e limite do Codex direto no painel (botão ⋯ ou clique direito).
- **Barra de menus**: ícone + métricas escolhidas (CPU, memória, disco, rede, térmico, sensor, limite do Codex opcional); popover com gráficos de CPU, memória, disco e rede, órfãos, sessões, servidores e maior CPU.
- **Dock**: sempre, só com a janela aberta (padrão: ao fechar a janela o app fica só na barra de menus) ou nunca.
- **Idiomas**: português, inglês e espanhol; segue o idioma do sistema ou a escolha em Ajustes.
- **Cmd+1…6**: navegar. **Cmd+R**: atualizar. **Cmd+Shift+P**: painel. **Cmd+Shift+Espaço**: pausar/retomar.

O painel não ganha foco durante atualizações; é arrastável pelo fundo e salva posição por tela. Ao desconectar uma tela, tenta trazer o painel para uma área visível. Ajustes permitem recuperar a posição manualmente. O painel participa de Spaces/tela cheia; cenários físicos não exercitados estão explicitados no relatório.

## Definições e privacidade

Cada métrica traz unidade, origem, horário e disponibilidade no snapshot. Passe o mouse sobre a leitura para ver a fonte; o rodapé mostra a atualização, e pausa/falha sinaliza dados antigos. I/O tem cadência de 6 s, volumes de 30 s. Não há coleta em shell.

Memória principal = **ativa + wired + compressor físico**. Não equivale ao indicador “Memória usada” do Monitor de Atividade nem a “pressão”. Por processo usamos **phys_footprint**, com páginas residentes separadas nos detalhes. Pressão vem de eventos Dispatch: até receber o primeiro evento, permanece desconhecida. Swap ocupado não é diagnóstico por si só.

Argumentos e variáveis de ambiente **não são coletados**. Nomes, executáveis, UID, PID e início são lidos localmente. Histórico de até 120 pontos e 10 minutos, somente em RAM. Acompanhamentos/ignorados usam identidade PID + início e ficam no UserDefaults; não migram automaticamente para uma nova execução do mesmo programa. Não há exportador de argumentos ou log contínuo de processos.

Uso de tokens: lido somente ao abrir a página Agentes, em modo leitura, de `~/.claude/projects/<projeto>/<sessão>.jsonl` e `~/.claude/projects/<projeto>/<sessão>/subagents/*.jsonl` (objeto `usage` das entradas do assistente) e de `~/.codex/sessions/AAAA/MM/DD/*.jsonl` (eventos `token_count`). Só arquivos gravados nos últimos 7 dias e as transcrições de sessões em execução, cada um a partir de onde a leitura anterior parou. **O conteúdo das mensagens nunca é guardado:** as linhas passam por um buffer pequeno reutilizado e só ficam, em memória, contagens de tokens, ids de modelo e de sessão, diretórios de trabalho e o id da última mensagem vista em cada arquivo — nada é gravado em disco.

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
