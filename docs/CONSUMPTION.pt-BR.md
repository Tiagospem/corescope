# Consumo observado

*English: [CONSUMPTION.md](CONSUMPTION.md)*

> **Histórico (v0.1.0).** Estas medições são do commit `d83bbf0`, a primeira versão nativa. A interface mudou desde então (árvore de processos, página Agentes, novos layouts do painel flutuante), e os números abaixo não descrevem a versão atual. O resumo atual está na tabela “Resource usage” do [README](../README.md#resource-usage).

16/10/2026, Mac arm64, macOS 27.0.1, 10 núcleos lógicos, 16 GiB. Build release com Swift `-O` e Rust release, assinatura ad hoc. Código final `d83bbf0`. Bundle local: **2,9 MiB** (não inclui toolchains/cache de compilação).

## Método e limites

`scripts/measure.c` observa somente o PID escolhido por `proc_pid_rusage(RUSAGE_INFO_V4)`, a cada segundo. Revalida início do processo, usa relógio monotônico e converte ticks Mach para nanossegundos antes de dividir pelo tempo decorrido. `100%` de CPU significa **um núcleo**; em dez núcleos, 10% nessa coluna equivale aproximadamente a 1% da capacidade lógica total, sem correção por diferenças de desempenho entre núcleos.

Memória é `ri_phys_footprint`, média aritmética de amostras e maior valor da janela; não é pico histórico do lançamento nem apenas RSS. Os JSON também guardam RSS final e despertares de pacote. **Todos os testes tiveram 0 despertares de pacote atribuídos por segundo**, mas isso não significa ausência de timers: despertares de interrupção aparecem separadamente.

A máquina continuou executando ferramentas de desenvolvimento e agentes. Não foi isolada, reiniciada nem teve processos de trabalho interrompidos. As janelas não incluíram novas chamadas de automação por nossa parte, porém houve interação e mudanças de seleção/árvore entre observações. Além disso, `sample` após a janela da tabela encontrou chamadas `mshMIGPerform`, `_AXXMIGCopyMultipleAttributeValues`, `NSTableViewCellMockElement` e criação de células. Portanto o custo observado inclui trabalho de acessibilidade e não estabelece quanto foi exclusivamente causado pelo coletor ou pela atualização normal da UI. O reset da sessão de automação não garante remover todos os observadores externos.

A tentativa de minimizar/fechar pela automação continuou retornando a janela de Ajustes. **Não consideramos essa janela uma medição comprovada de modo oculto**, apesar do nome histórico da intenção. Nenhum número foi descartado por ser desfavorável.

## Resultados

| Cenário observado | Duração | CPU de um núcleo | Footprint médio / maior | Despertares de interrupção | Dados brutos |
|---|---:|---:|---:|---:|---|
| Visão geral final | 40.1 s | 2.79% | 78.4 / 112.8 MiB | 3.06/s | [consumption-final-overview.json](consumption-final-overview.json) |
| Tentativa de minimizar; estado oculto não confirmado | 40.1 s | 3.98% | 114.4 / 121.3 MiB | 2.14/s | [consumption-minimize-attempt.json](consumption-minimize-attempt.json) |
| Tabela completa final, sessão interativa | 40.3 s | 33.72% | 143.9 / 151.4 MiB | 2.83/s | [consumption-final-processes.json](consumption-final-processes.json) |
| Tabela após reset da automação, sessão interativa | 35.1 s | 13.94% | 160.4 / 166.2 MiB | 2.31/s | [consumption-processes-after-ui-reset.json](consumption-processes-after-ui-reset.json) |
| Exploração inicial antes do ajuste da árvore | 45.2 s | 5.20% | 110.7 / 173.7 MiB | 6.15/s | [consumption-visible.json](consumption-visible.json) |
| Tabela anterior ao ajuste da árvore | 35.1 s | 9.43% | 153.3 / 204.0 MiB | 10.25/s | [consumption-processes-quiet.json](consumption-processes-quiet.json) |

Os arquivos com “quiet”/“final” preservam os nomes da coleta; “quiet” significa ausência de novas chamadas explícitas nossas durante a janela, não certificação de ambiente ocioso. Não se deve inferir uma melhora percentual entre execuções com cargas, superfícies e interações diferentes.

## Histórico persistente: ligado vs desligado

16/10/2026, mesmo Mac, build release deste branch. Cada execução: lançamento novo do app, janela principal na **Visão geral** (com os novos cards de CPU por núcleo e detalhe da memória), coleta a cada 3 s, 20–25 s de aquecimento e `scripts/measure.c` por 120 s. O histórico foi ligado só pela linha de comando (`-historyEnabled YES`, domínio de argumentos), sem alterar a preferência salva. A máquina estava carregada por builds e agentes de outras sessões (núcleos E perto de 100%), por isso a linha de base fica acima dos 2,8% da tabela anterior; compare as linhas entre si, não com execuções antigas.

| Histórico | CPU de um núcleo | Footprint médio / maior | Despertares de interrupção |
|---|---:|---:|---:|
| Desligado | 4.55% | 88.7 / 125.7 MiB | 3.40/s |
| Ligado (7 dias) | 4.78% | 95.0 / 135.0 MiB | 3.24/s |

Diferença observada: **+0,2 ponto de CPU** (dentro da variação entre execuções: outra execução ligada mediu 4,48%) e **~+6 MiB de footprint** (acumulador do minuto e cache de páginas do SQLite). Escrita: um único commit por minuto no WAL (`stat` do `-wal` muda só na virada do minuto); 20 linhas de top por minuto, identidades de processo deduplicadas (28 após 13 minutos), ~366 KB após 14 minutos com WAL ainda não reciclado. Medição feita com a janela visível; o custo com janela fechada (cadência de 10 s) não foi medido nesta rodada.

## Metas de engenharia e estado

Metas propostas para aceitação, não requisitos medidos previamente nem promessa de desempenho universal:

- Visão geral sem interação: CPU média até 5% de um núcleo; footprint médio até 128 MiB. A janela observada ficou abaixo, mas precisa de repetição isolada para caracterizar baseline.
- Tabela completa sem interação: CPU média até 10% de um núcleo; footprint médio até 200 MiB e pico de janela até 256 MiB. **CPU não atingida nas últimas janelas desta sessão**; memória ficou abaixo. O perfil exige separar observação AX de atualização normal antes de decidir uma otimização adicional. Não declarar a leveza de todas as superfícies como aprovada.
- Somente barra, janela/painel ocultos: CPU média até 1% de um núcleo; ainda **não validada**. O código reduz cadência para pelo menos 10 s, mas implementação não é evidência de resultado.
- Pacote menor que 10 MiB: observado 2,9 MiB.
- Histórico limitado por quantidade/tempo: testes passam; não substituem um ensaio prolongado de estabilidade de memória.
- Energia em watts/joules ou Energy Impact: **indisponível**. Campos brutos de energia não foram interpretados sem unidade/contrato confiável. Não há conclusão sobre autonomia da bateria.

## Reproduzir

```sh
cd corescope
clang -O2 scripts/measure.c -o build/measure
pgrep -x CoreScope
# Substituir PID pelo valor conferido; o medidor não envia sinais.
./build/measure PID 60
```

Para uma comparação controlada: use o mesmo build, intervalo de 3 s, número semelhante de processos, sem interação ou captura AX durante a janela; execute separadamente visão geral, tabela, somente barra e painel. Confirme visualmente o estado antes e depois. Rode por alguns minutos em vez de extrapolar destas janelas curtas. Não altere serviços do usuário para obter números artificialmente baixos.

## Contêineres (ADR 003)

16/10/2026, mesmo Mac, OrbStack com 6 contêineres em execução (5 do usuário + `nginx:alpine` de teste). `scripts/measure.c`, 60 s por janela após 20 s de aquecimento, alternando o build anterior (`a854cec`) e o novo; com o app oculto (`NSRunningApplication.hide`) nenhuma leitura de contêiner ocorre. Outras sessões compilavam e executavam CoreScope ao mesmo tempo: a variação entre janelas iguais é maior que a diferença medida.

| Cenário | Build | CPU de um núcleo | Footprint médio / maior |
|---|---|---:|---:|
| Visão geral visível (com cartão Contêineres) | anterior | 4.78% · 4.72% | 99.8 / 134.7 · 89.9 / 124.0 MiB |
| Visão geral visível (com cartão Contêineres) | novo | 5.14% · 4.35% | 93.7 / 130.8 · 92.8 / 128.7 MiB |
| App oculto | anterior | 1.31% | 75.3 / 115.6 MiB |
| App oculto | novo | 1.53% | 85.8 / 128.8 MiB |

Uma leitura completa (lista + 6 stats `one-shot`) leva ~70 ms de relógio, quase toda à espera do motor, a cada 5 s. Conclusão: custo não distinguível do ruído nesta máquina; uma janela oculta isolada não basta para afirmar diferença de memória.
