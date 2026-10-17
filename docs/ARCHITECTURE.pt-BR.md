# ADR 001 — núcleo local e interface nativa

*English: [ARCHITECTURE.md](ARCHITECTURE.md)*

Decisão registrada antes da implementação, em 16/10/2026.

Ambiente observado: macOS 27.0.1 (26A434), arm64, Swift 6.4, Rust 1.98.1 e Command Line Tools. Sem projeto preexistente. Deployment target: macOS 14, pela disponibilidade das APIs de UI usadas; compatibilidade em 14 ainda exige teste em outra máquina. Build de desenvolvimento para a arquitetura local, assinatura ad hoc.

Rust coleta e interpreta dados, mantém buffers limitados, calcula taxas por relógio monotônico, aplica histerese e revalida cada ação de processo. Um adaptador C pequeno usa os headers do SDK para as estruturas Mach/libproc/IOKit; não contém diagnósticos nem armazenamento. Isso evita copiar layouts de ABI do kernel para Rust, inclusive estruturas VM que mudaram no SDK 27.

SwiftUI apresenta janela e MenuBarExtra; AppKit fornece NSPanel não ativador. Um único serviço Swift serial em background chama Rust, entrega snapshots imutáveis e recebe eventos públicos de pressão, repouso e estado térmico. Não há servidor, navegador, banco de dados, telemetria ou coleta de argumentos/env.

FFI: JSON UTF-8 em ponteiro alocado por Rust, copiado por Swift e liberado exatamente uma vez por `cs_free`. Entradas permanecem emprestadas durante a chamada. Mutex serializa estado; catch_unwind impede panic atravessando C. Ponteiros inválidos continuam proibidos pelo contrato. Sinais retornam resultado explícito; identidade inclui PID, início em microssegundos, UID e executável. macOS não oferece sinalização atômica por PID + início: uma janela residual de corrida é documentada.

Cadências: 3 s padrão, 10 s em economia/sem superfícies de detalhe, inventário de volumes 30 s, I/O físico 6 s; pausa no repouso e reinício dos deltas no retorno. Limites: 120 amostras e 10 minutos; até 12 processos acompanhados. Sensores Celsius sem API pública confiável são marcados não suportados. Eventos de pressão ficam desconhecidos até o primeiro evento, sem confundir ocupação de RAM com pressão.

## ADR 002 — temperatura NVMe via interface pública

A investigação solicitada do Disk Drill identificou Smartmontools; o SDK instalado contém `IOKit/storage/nvme/NVMeSMARTLibExternal.h`. Por isso a primeira versão passou a consultar **diretamente** `IONVMeSMARTInterface.SMARTReadData`, sem executar ou incorporar o Disk Drill/smartctl. A associação parte do ID do driver físico e sobe apenas seus ancestrais até `NVMe SMART Capable`.

Leitura de 512 bytes, somente leitura, a cada 30 s, na fila serial; interfaces COM/IOKit e portas são liberadas. Não há ativação de SMART, autoteste, escrita, root ou helper. Rust valida a faixa, converte Kelvin para Celsius e preserva origem, horário e estados separado para falta de suporte, permissão e falha temporária. O campo NVMe tem resolução de 1 K; casas decimais são conversão de unidade, não precisão adicional. A temperatura é composta do controlador, sem atribuí-la ao gabinete/adaptador.

Validação ao vivo neste hardware: APPLE SSD AP0256Z e KINGSTON SNV3S1000G retornaram dados sem elevação. Isso não estabelece suporte a todos os discos SATA/USB/Thunderbolt. Para ATA/SATA ou bridges sem interface pública compatível, a ausência de suporte continua explícita. Veja DISKDRILL-TEMPERATURE.pt-BR.md para a investigação estática, distinta desta execução.
