# Auditoria de segurança do CoreScope

Escopo: commit `d2ad0ff` em 17/10/2026. A revisão estática adaptou as cinco
categorias solicitadas à arquitetura nativa macOS. Foram confirmados dois
achados de severidade média. A hipótese de ação na tela bloqueada está
expressamente condicionada à apresentação pelo macOS e não foi reproduzida
fisicamente. Nenhum processo real foi sinalizado na auditoria.

## Arquivos

- `relatorio-auditoria-seguranca.pdf`: relatório de seis páginas, A4, com
  gráficos vetoriais e issues completas no final.
- `ISSUES.md`: as mesmas duas issues, em Markdown copiável.
- `generate_report.py`: fonte única dos textos, issues e gráficos.

## Regenerar

No macOS, com Python 3 e ReportLab 4.x em um ambiente isolado ou no runtime
bundled do Codex:

```sh
python3 docs/security-audit/generate_report.py
```

O script usa Arial e Courier New do macOS e não acessa a rede. Se ReportLab
não estiver disponível, instale-o apenas no ambiente virtual escolhido.

## Conferência feita nesta geração

`pdfinfo` confirmou A4 e seis páginas. `pdftotext` confirmou os delimitadores
das duas issues. `pdfimages -list` não encontrou imagens raster; a rosca e as
barras são vetoriais. As seis páginas foram rasterizadas para inspeção visual,
incluindo capa, gráficos, tabela de achados e as duas issues.
