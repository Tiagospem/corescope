# Revisão final independente de interface

*English: [FINISH-REVIEW.md](FINISH-REVIEW.md)*

> **Histórico (v0.1.0).** Esta revisão inspecionou a primeira versão nativa (commit `d83bbf0`). A interface mudou desde então (árvore de processos, página Agentes, encerramento ✕ na linha, novos layouts do painel flutuante); as telas e números de linha abaixo (como `native/CoreScope.swift:115`) descrevem aquela versão, e o diretório `captures/` citado não está mais no repositório.

Data: 16/10/2026. Código inspecionado: `d83bbf0`. Escopo: primeira versão funcional nativa de CoreScope. Revisão somente de leitura do produto e do código; este documento é o único arquivo escrito pelo revisor.

## 1. Validade da captura

Foram abertas e inspecionadas as capturas reais fornecidas `captures/overview.png` (1080 × 1000) e `captures/sensors.png` (1080 × 760). Não há cortes ou sobreposições materiais nessas imagens. A captura de sensores apresenta horário próprio anterior ao da visão geral; ela valida a composição e o conteúdo capturado, não a atualidade das leituras no momento da revisão.

O menu anterior foi removido após a correção. Não existe uma captura atual do menu ou do painel disponível para esta revisão. O raster antigo não representa a implementação corrigida. O checkpoint `overview-first.png` não foi usado como prova final.

Não houve operação de UI, coleta de novas capturas ou interação durante a medição de consumo do responsável pela implementação. Não foi verificada independentemente a correspondência do binário em execução com o commit; a inspeção de código confirmou o HEAD acima.

## 2. Aderência ao brief e ao contrato

A direção observada é coerente com macOS nativo: fontes do sistema, SF Symbols, sidebar, controles convencionais e conteúdo compacto. A visão geral apresenta diagnóstico e ressalva antes das métricas; CPU total tem escala 0–100% e memória tem definição explícita sem ser chamada de pressão. Sensores separa estado térmico de temperatura e mostra identificação dos dispositivos, origem e horário das leituras, além da ausência de suporte para temperatura de CPU/SoC.

A aparência de seleção acompanha a cor de destaque observada do sistema. Nenhuma mudança estética foi solicitada com base em preferência pessoal. Não há mockup aprovado; a avaliação usa PRODUCT.md, docs/BRIEF.txt, docs/SURFACE.pt-BR.md e o craft-floor da skill Impeccable. Detectores web não foram executados porque a implementação é nativa.

O código de controles de processo apresenta confirmação separada de SIGTERM/SIGKILL e lista explícita de alvos. Esta revisão de interface não certifica execução de sinais nem a segurança da implementação do coletor.

## 3. Achados materiais e correções

Os dois achados anteriores foram tratados no código:

- **Menu com contraste insuficiente no raster anterior:** `native/CoreScope.swift:115` agora aplica `Color(nsColor: .windowBackgroundColor)` como fundo opaco de MenuSummary. A correção elimina a dependência do material translúcido que motivou o achado. Correção confirmada por código; contraste final renderizado ainda não medido. O contraste aproximado de 2,5:1 medido anteriormente pertence somente à captura descartada e não deve ser atribuído ao build corrigido.
- **Aviso de dados antigos condicionado à opção térmica:** `native/Panel.swift:119` agora mantém “Pausado”/“Ao vivo” no cabeçalho, fora de `thermalInPanel`. O esmaecimento geral de 0,65 foi retirado em `native/Panel.swift:156–159`. A leitura antiga passa a ter rótulo independente da seleção térmica. Correção confirmada por código; estado final não capturado.

Não foram encontrados novos defeitos materiais nas duas imagens atuais. Não se abriu nova rodada de polimento.

## 4. Limites da revisão

Aprovação visual limitada à visão geral e sensores nas dimensões e no tema escuro capturados. Sem aprovação visual final para menu, painel, processos, armazenamento, ajustes, modo claro, tamanho mínimo, foco de teclado, VoiceOver, aumento de contraste, redução de transparência ou estados de erro/pausa. Implementação por código não equivale a teste desses estados.

Spaces, tela cheia, múltiplos monitores, desconexão física e repouso/retorno físicos permanecem fora desta revisão. Compilação, assinatura, consumo e testes funcionais pertencem aos relatórios do implementador, não foram repetidos pelo revisor.

## 5. Disposição única

**recapture**

As duas correções estão aceitas por inspeção de código e as superfícies atuais capturadas não apresentam impedimento material. Falta somente evidência renderizada do menu corrigido e do painel pausado com a opção térmica desligada para fechar os achados visuais. Esta disposição não solicita redesenho, reconstrução nem nova caça de polimento. A primeira versão funcional pode ser entregue com essa pendência visual explicitamente declarada; não deve ser descrita como visualmente validada em todas as superfícies.
