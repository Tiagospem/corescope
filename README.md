# CoreScope

Monitor local para macOS, com núcleo Rust e interface SwiftUI/AppKit. Métricas reais, histórico curto e controle manual de processos. Sem servidor, webview, telemetria ou otimizações automáticas.

## Compilar e abrir

Requisitos: macOS 14+, Command Line Tools com Swift e SDK macOS, Rust/Cargo. Build validado em macOS 27.0.1 arm64, Swift 6.4 e Rust 1.98.1; macOS 14 e Intel ainda precisam de validação física. A primeira compilação baixa as dependências Cargo; o aplicativo não usa rede.

```sh
cd "/Volumes/HD Externo/Documents/testes/CoreScope"
./scripts/test.sh
./scripts/build.sh
open build/CoreScope.app
```

Saída: `build/CoreScope.app`. Assinatura **ad hoc**, sem Developer ID/notarização, destinada a este ambiente de desenvolvimento. Não altera SIP, não instala helper, não solicita root ou Full Disk Access. O build não instala nada em `/Applications`. Não copie o app enquanto o build estiver em execução.

## Uso

- **Visão geral**: sinais que merecem atenção, CPU total, memória, histórico e processos com maior CPU.
- **Processos**: busca por nome/PID/usuário, colunas ordenáveis, filtros mínimos, árvore, candidatos a revisão e até 12 identidades acompanhadas. Duplo clique ou Enter abre detalhes. CPU por processo pode superar 100%: 100% significa um núcleo.
- **Armazenamento**: volumes separados dos dispositivos físicos; não some capacidade APFS. I/O é atividade, não saturação.
- **Sensores**: estado térmico público; leituras em Celsius só quando houver uma fonte realmente suportada. Leitura real validada no SSD Apple interno e Kingston externo pela API pública NVMe, sem root. SATA e bridges incompatíveis permanecem sem suporte. Consulte a investigação específica do Disk Drill em `docs/`.
- **Ajustes**: cadência, tema, métricas e ordem do menu, painel, limiares e início de sessão opcional (desligado por padrão).
- **Cmd+1…5**: navegar. **Cmd+R**: atualizar. **Cmd+Shift+P**: painel. **Cmd+Shift+Espaço**: pausar/retomar. Fechar a janela mantém o menu; Cmd+Q encerra o app.

O painel não ganha foco durante atualizações; é arrastável pelo fundo e salva posição por tela. Ao desconectar uma tela, tenta trazer o painel para uma área visível. Ajustes permitem recuperar a posição manualmente. O painel participa de Spaces/tela cheia; cenários físicos não exercitados estão explicitados no relatório.

## Definições e privacidade

Cada métrica traz unidade, origem, horário e disponibilidade no snapshot. Passe o mouse sobre a leitura para ver a fonte; o rodapé mostra a atualização, e pausa/falha sinaliza dados antigos. I/O tem cadência de 6 s, volumes de 30 s. Não há coleta em shell.

Memória principal = **ativa + wired + compressor físico**. Não equivale ao indicador “Memória usada” do Monitor de Atividade nem a “pressão”. Por processo usamos **phys_footprint**, com páginas residentes separadas nos detalhes. Pressão vem de eventos Dispatch: até receber o primeiro evento, permanece desconhecida. Swap ocupado não é diagnóstico por si só.

Argumentos e variáveis de ambiente **não são coletados**. Nomes, executáveis, UID, PID e início são lidos localmente. Histórico de até 120 pontos e 10 minutos, somente em RAM. Acompanhamentos/ignorados usam identidade PID + início e ficam no UserDefaults; não migram automaticamente para uma nova execução do mesmo programa. Não há exportador de argumentos ou log contínuo de processos.

O candidato a possível abandono requer uma mudança de pai observada, pai com nome de ferramenta de desenvolvimento (heurística), idade e recursos retidos. Confiança moderada: um serviço legítimo pode cumprir esses critérios. Não identifica processos abandonados que já existiam antes do monitor. Nenhuma ação automática.

Encerramento: só usuário atual e processos elegíveis, com confirmação do executável e impacto. SIGTERM primeiro; SIGKILL é separado e avisa sobre perda de dados. Árvore usa lista fixa, filhos antes do pai, com revalidação de cada identidade. Não há `killall`, `pkill` ou sinalização de grupos. O macOS não oferece um identificador de processo atômico para `kill`: a revalidação reduz, mas não elimina matematicamente, a corrida residual de reutilização de PID.

## Organização

| Diretório | Responsabilidade |
|---|---|
| `core/src/lib.rs` | processamento Rust, diagnóstico, histórico, políticas de processo, FFI e testes |
| `core/src/os.rs` | tipos ABI e acesso seguro aos registros brutos |
| `core/src/macos.c` | adaptador mínimo para estruturas/API públicas do SDK |
| `native/` | modelos, serviço serial, SwiftUI, MenuBarExtra e NSPanel |
| `scripts/` | build, testes e medidor externo somente leitura |
| `docs/` | arquitetura, API, validação, consumo e investigação de sensores |
| `captures/` | capturas do aplicativo real |

Contrato de memória FFI em `native/CoreScopeFFI.h` e `docs/ARCHITECTURE.md`. A UI copia UTF-8 e sempre chama `cs_free`; Rust contém panics, e todo o estado é serializado. O adaptador C não toma decisões de diagnóstico.

## Evidências da entrega

[Funcionalidades e validação](docs/VALIDATION.md) · [Consumo observado](docs/CONSUMPTION.md) · [Investigação REA / Disk Drill](docs/DISKDRILL-TEMPERATURE.md) · [Fontes das APIs](docs/API-SOURCES.md) · [Capturas reais](captures/README.md) · [Revisão visual](docs/FINISH-REVIEW.md).
