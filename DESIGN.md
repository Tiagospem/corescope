---
name: CoreScope
description: Monitor local de macOS com evidências legíveis e controle manual.
rounded:
  diagnostic: "12pt"
spacing:
  compact: "6pt"
  related: "12pt"
  inset: "16pt"
  section: "24pt"
typography:
  metric:
    fontFamily: "macOS system, rounded design"
    fontSize: "30pt"
    fontWeight: 500
---

# Design System: CoreScope

## Overview

**Creative North Star: "Seu Mac, em perspectiva."**

CoreScope segue a identidade macOS nativa exigida no brief: conteúdo compacto, hierarquia discreta, tipografia do sistema e controles familiares. A interface ajuda a investigar sinais antes de agir; a precisão do estado exibido faz parte de sua linguagem visual.

Este registro descreve o SwiftUI/AppKit implementado, sem converter cores dinâmicas em uma paleta fixa ou simular componentes web. As unidades do frontmatter são pontos lógicos do macOS. Fontes sem tamanho explícito seguem os estilos semânticos de SwiftUI.

**Key Characteristics:**

- Tipografia do sistema, SF Symbols e algarismos tabulares nas métricas.
- Destaque progressivo acompanhado por texto e símbolos.
- Três superfícies complementares: janela, barra de menus e painel flutuante.
- Dados ausentes ou antigos identificados por palavras, nunca apresentados como leituras normais.

A revisão visual disponível cobre visão geral e sensores no tema escuro. Menu e painel tiveram correções confirmadas por código, mas ainda requerem recaptura; as demais superfícies e condições de acessibilidade não têm validação visual completa. Ver `docs/FINISH-REVIEW.md`.

## Colors

A paleta usa cores e materiais semânticos do sistema; valores RGB/hex dependem da aparência e da configuração do macOS e não são tokens fixos deste produto.

### Primary

- **Destaque do sistema** (`Color.accentColor`): seleção nativa, micrográfico de CPU e capacidade de volumes em condição habitual. A cor acompanha o sistema; não fixar azul a partir do contrato inicial.
- **Memória** (`Color.teal`): diferencia a série de memória da série de CPU, junto de rótulos explícitos.

### Neutral

- **Texto principal e secundário**: estilos de primeiro plano padrão e `.secondary`, conforme hierarquia.
- **Fundo de janela** (`NSColor.windowBackgroundColor`): fundo opaco do resumo do menu e alternativa do painel com redução de transparência.
- **Contexto do diagnóstico** (`.quaternary.opacity(0.5)`): agrupamento discreto da evidência principal.
- **Materiais nativos**: `.bar` no rodapé; `.regularMaterial` no painel quando permitido.

Atenção usa `.orange`; crítico e erros usam `.red`. O aviso de dados antigos usa laranja com opacidade de 0,12. A cor acompanha descrição e símbolo, sem carregar sozinha a informação.

**The Evidência Rule.** Ausência de leitura não recebe aparência de estado normal; pausa e desatualização têm rótulo independente dos sensores selecionados.

## Typography

A família padrão é a fonte de sistema escolhida pelo macOS. Não há fonte externa. Os títulos de seção usam `.title2.weight(.semibold)`; agrupamentos usam `.headline`; explicações usam `.callout`, `.caption` e `.caption2` com hierarquia secundária.

Os números principais de CPU e memória usam o papel `metric` do frontmatter e `.monospacedDigit()`. Tabelas e resumos também adotam algarismos tabulares para reduzir saltos de largura. Caminhos de executáveis usam `.system(.caption, design: .monospaced)`, com seleção de texto habilitada. Não impor tamanho em pixels aos estilos semânticos.

## Layout

A janela usa `NavigationSplitView` com sidebar entre 170 e 220 pt, ideal de 190 pt. O tamanho inicial é 1080 × 760 pt e o mínimo é 850 × 590 pt. Visão geral, armazenamento e sensores rolam verticalmente; processos usa tabela nativa com colunas dimensionadas e controles acima.

A hierarquia da visão geral começa por evidência e ressalva, seguida de CPU/memória, métricas auxiliares e processos de maior consumo. As páginas de leitura usam margem de 26 pt; processos, 22 pt. Seções usam intervalos entre 22 e 24 pt, enquanto elementos relacionados usam o ritmo compacto registrado no frontmatter.

O resumo do menu declara largura de 330 pt e padding de 20 pt. O painel tem base de 270 × 190 pt, ou altura de 215 pt com sensor selecionado; o ajuste existente multiplica suas dimensões entre 0,85 e 1,4. Esse ajuste não é uma escala tipográfica global. A posição fica restrita à área visível do monitor. Não há breakpoints web.

## Elevation & Depth

Profundidade vem de janelas, folhas de confirmação, divisores e materiais nativos. Não há sombra personalizada nem animação de transição definida pelo aplicativo. O painel é um `NSPanel` não ativante, com nível normal ou flutuante configurável; sua opacidade pode variar de 0,5 a 1 e é forçada a 1 quando o macOS pede redução de transparência.

O resumo do menu usa fundo opaco para preservar legibilidade. Não substituir esse fundo por translucidez sem verificar novamente o contraste renderizado.

## Shapes

O contêiner de diagnóstico usa o arredondamento `diagnostic`. Campos de busca e filtros usam `.roundedBorder`. Botões, seleção de listas, tabelas, formulários agrupados e folhas usam a forma fornecida pelo macOS; seus raios e estados não são redefinidos pelo aplicativo.

Os micrográficos usam traço de 1,6 pt com pontas e junções arredondadas. Lacunas de disponibilidade interrompem o traço; não são ligadas por uma curva fictícia.

## Components

- **Navegação:** lista lateral com SF Symbol e nome para cada área; seleção do sistema e atalhos Cmd+1 a Cmd+5. Rodapé combina origem, horário e contagem de processos.
- **Linha de métrica:** título à esquerda, valor alinhado à direita e algarismos tabulares; ajuda contextual com origem, horário e disponibilidade. Elementos combinados para acessibilidade.
- **Micrográfico:** `Canvas` com escala documentada, sem animação própria; descrição acessível com quantidade de amostras e último valor.
- **Diagnóstico:** símbolo, título e explicação em contêiner discreto. Cor secundária em estado normal, laranja para atenção e vermelho para crítico.
- **Explorador de processos:** tabela nativa, busca, filtros e seleção antes da abertura de detalhes. Ausência de resultados recebe mensagem explícita.
- **Detalhe e confirmação:** folhas separadas para inspeção e ação. Botões comuns para encerramento solicitado; papel `.destructive` para força e confirmação. Alvos, executável e impacto permanecem visíveis; controles bloqueados respeitam elegibilidade e atualidade.
- **Ajustes:** `Form` agrupado, `Picker`, `Toggle`, `Slider` e valores textuais. Foco, hover e estados desabilitados são responsabilidade dos controles nativos.
- **Menu e painel:** resumo compacto com números e estado explícito. O painel mantém “Pausado”/“Ao vivo” mesmo com a opção térmica desligada.

## Do's and Don'ts

### Do:

- **Do** manter estilos semânticos do macOS, SF Symbols e algarismos tabulares nas métricas.
- **Do** acompanhar estados com texto, símbolo, origem e contexto da leitura.
- **Do** preservar confirmação separada e impacto visível nas ações destrutivas.
- **Do** distinguir implementação, captura real e teste físico nos registros de validação.

### Don't:

- **Don't** congelar as cores dinâmicas do macOS em valores hex extraídos de uma captura.
- **Don't** converter estado térmico em graus Celsius nem ocupação de RAM em pressão.
- **Don't** ocultar o estado de pausa quando uma categoria de métrica estiver desativada.
- **Don't** introduzir dashboard web, fontes externas ou animação decorativa nesta identidade nativa.
