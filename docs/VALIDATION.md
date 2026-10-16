# Validação — CoreScope 0.1.0

Data: 16/10/2026. Host observado: macOS 27.0.1 arm64, 16 GiB físicos, 10 núcleos lógicos. Rust 1.98.1 e Swift 6.4. Deployment target 14, sem validação física de macOS 14 ou Intel.

## Testes automatizados

`./scripts/test.sh`: **15 testes Rust + 6 verificações nativas passaram**. `cargo fmt --check` e Clippy com `-D warnings` passaram.

Cobertura: ticks de CPU/normalização; conversão Mach com carga real descartável; contadores reiniciados; intervalo após repouso; histerese; limites por quantidade/idade do histórico; Celsius NVMe válido, inválido, indisponível e negado; ausência de falsos candidatos com apenas PPID/idade; critérios combinados para candidato; rejeição de PID inválido/próprio; início/executável divergentes; SIGTERM e SIGKILL em filhos criados pelo teste; amostra real; reset; JSON/ownership FFI; conjunto exato de descendentes, ordem e ciclos; painel fora da tela e tela com origem negativa.

Nenhum teste sinalizou processos reais de trabalho. A carga do teste usa `/usr/bin/yes` criado pelo teste, por 500 ms, com stdout descartado; encerramentos usam `/bin/sleep` criado pelo teste. Não se chama killall/pkill/grupos.

## Métricas observadas

- CPU, RAM, compressor, swap e aproximadamente 430–530 processos disponíveis durante o trabalho, com variação real do sistema.
- CPU por processo corrigida/validada para tempo absoluto Mach em Apple Silicon; 100% equivale a um núcleo.
- Dispositivos físicos identificados como APPLE SSD AP0256Z Media e KINGSTON SNV3S1000G Media. Volumes APFS listados separadamente.
- Leitura NVMe sem root às 09:55:31: Apple **50,85 °C**, Kingston **47,85 °C**, convertidos de 324 K e 321 K. Temperaturas pontuais, não benchmark térmico; resolução original 1 K.
- Pressão de memória permaneceu “aguardando evento” na sessão: não foi forçado um evento por consumo artificial de RAM.
- Estado térmico “Moderado” observado; não é valor de temperatura.

## Estado das funcionalidades

| Funcionalidade | Implementação / validação | Limitação |
|---|---|---|
| Núcleo e FFI | Compilados e exercitados; testes Rust | Ponteiros do contrato devem ser válidos; catch_unwind não transforma UB em erro |
| CPU/memória/processos | Dados reais e teste de escala | Alguns processos protegidos ficam sem métricas/sem permissão |
| Diagnósticos e histerese | Testes de janelas e recuperação | Heurísticas explicáveis, não prova causal de lentidão |
| Pressão de memória | Dispatch com disponibilidade explícita | Nenhum evento crítico real provocado |
| Menu configurável | MenuBarExtra nativo, dados compartilhados | Espaço da barra depende do macOS e dos outros apps |
| Janela, filtros, árvore e detalhes | SwiftUI nativo; busca CoreScope retornou um resultado, detalhes abertos e encerramento próprio desabilitado | Árvore observada; não foi exercitada toda combinação de filtros |
| SIGTERM/SIGKILL | Revalidação e confirmação, testes com descartáveis | Corrida residual entre revalidação e kill; sem helper privilegiado |
| Árvore de encerramento | Lista fixa, revalidação por alvo, teste de descendentes | Novos filhos posteriores à confirmação não são incluídos |
| Candidatos a abandono | Mudança de pai observada + sinais adicionais | Sem histórico anterior ao lançamento; não comprova abandono |
| Histórico acompanhado | Até 12 identidades; até 120 pontos/10 min | Não persiste histórico nem segue PID reutilizado |
| I/O e volumes | APIs reais; nomes dos dois dispositivos conferidos | Sem diagnóstico de latência/saturação; inventário cacheado em 30 s |
| Temperatura NVMe | **Leitura real dos dois SSDs, sem root** | SATA, bridges incompatíveis e temperatura do adaptador não implementados |
| Seleção de sensor | Sensor suportado selecionável para menu/painel | ID IOKit muda após reconexão; pode ser necessário selecionar novamente |
| Painel flutuante | NSPanel não ativador, tamanho/opacidade/trava, UUID da tela | Troca física de monitor/Spaces/tela cheia ainda exige matriz manual |
| Repouso/retorno | Notificações e reset de deltas; testes de reset | Não suspendemos a máquina com o trabalho do usuário ativo |
| Temas/acessibilidade | Cores/controles de sistema, teclado, redução de transparência, sem animações próprias | VoiceOver completo e todas as combinações de contraste ainda não certificados |
| Início de sessão | SMAppService opcional, inicialmente desligado | Não ativado para não mudar a sessão do usuário; ad hoc pode ser recusado |
| Energia | Limitação explicitada | Sem watts/joules/Energy Impact confiável por API integrada |

## Roteiro de aceitação física restante

1. Arrastar painel entre dois monitores, travar, desconectar/reconectar monitor, verificar recuperação e preferências por UUID.
2. Alternar Spaces e aplicativos em tela cheia com painel habilitado; confirmar que não toma foco. Os flags foram configurados, não equivalem a este teste.
3. Repousar e retomar com o monitor ligado, conferir lacuna/primeira amostra sem delta.
4. Desconectar/reconectar um disco externo ocioso e seguro para remoção; não desconectamos o volume onde está o trabalho do usuário.
5. Verificar VoiceOver/Full Keyboard Access, launch at login e sistema mínimo em máquina de teste.

As limitações acima são fronteiras de validação, não simulações ou resultados inventados.

## Interface exercitada

Aplicativo empacotado aberto pelo caminho `build/CoreScope.app`. Capturas reais em `captures/`: visão geral com históricos em atualização, sensores com os dois NVMe e detalhes do próprio CoreScope. Busca por “CoreScope” reduziu a lista a um resultado; duplo clique abriu os detalhes com origem, início, memória e ações de encerramento bloqueadas. Atalhos de navegação para Processos, Ajustes, Visão geral e Sensores foram exercitados.

A revisão visual encontrou contraste insuficiente no menu e indicador de pausa condicionado à opção térmica do painel. Ambos foram corrigidos, recompilados e revisados por código; a recaptura específica desses dois estados ainda está pendente. Ver `FINISH-REVIEW.md`. Não equiparar isso a uma aprovação visual completa de todas as preferências.

Consumo medido externamente, com deltas de libproc e relógio monotônico: metodologia e resultados em `CONSUMPTION.md`. Consultas de acessibilidade à tabela completa produziram custo adicional visível; não houve novas chamadas de UI durante as janelas do medidor, mas uma amostragem de pilha posterior ainda encontrou requisições de acessibilidade à tabela. Portanto essas janelas não comprovam um baseline sem observadores externos.
