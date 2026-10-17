#!/usr/bin/env python3
"""Regenera o relatório PDF e as duas issues da auditoria do HEAD d2ad0ff.

Dependência: reportlab 4.x no ambiente Python escolhido. Nenhuma rede ou instalação
global é necessária. Os gráficos são desenhados como vetores no próprio PDF.
"""

from __future__ import annotations

from html import escape
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    Flowable,
    Frame,
    KeepTogether,
    PageBreak,
    PageTemplate,
    Paragraph,
    Preformatted,
    Spacer,
    Table,
    TableStyle,
)


HERE = Path(__file__).resolve().parent
OUT = HERE / "relatorio-auditoria-seguranca.pdf"
ISSUES_OUT = HERE / "ISSUES.md"
PAGE_W, PAGE_H = A4
MARGIN = 20 * mm
INNER_W = PAGE_W - 2 * MARGIN

# Paleta requerida no pedido. Não trocar por tons aproximados.
CRITICAL = colors.HexColor("#B91C1C")
HIGH = colors.HexColor("#EA580C")
MEDIUM = colors.HexColor("#D97706")
LOW = colors.HexColor("#2563EB")
STRENGTH = colors.HexColor("#059669")
INK = colors.HexColor("#122235")
MUTED = colors.HexColor("#475569")
HAIRLINE = colors.HexColor("#CBD5E1")
PAPER_TINT = colors.HexColor("#F8FAFC")
NAVY = colors.HexColor("#102C3D")


def fonts() -> None:
    root = Path("/System/Library/Fonts/Supplemental")
    for name, filename in [
        ("ArialAudit", "Arial.ttf"),
        ("ArialAudit-Bold", "Arial Bold.ttf"),
        ("CourierAudit", "Courier New.ttf"),
    ]:
        pdfmetrics.registerFont(TTFont(name, str(root / filename)))
    pdfmetrics.registerFontFamily(
        "ArialAudit", normal="ArialAudit", bold="ArialAudit-Bold"
    )


fonts()
styles = getSampleStyleSheet()
styles.add(
    ParagraphStyle(
        name="ReportTitle", fontName="ArialAudit-Bold", fontSize=26,
        leading=32, textColor=INK, spaceAfter=12,
    )
)
styles.add(
    ParagraphStyle(
        name="ReportH1", fontName="ArialAudit-Bold", fontSize=16,
        leading=20, textColor=INK, spaceBefore=5, spaceAfter=9,
    )
)
styles.add(
    ParagraphStyle(
        name="ReportH2", fontName="ArialAudit-Bold", fontSize=11,
        leading=15, textColor=INK, spaceBefore=8, spaceAfter=4,
    )
)
styles.add(
    ParagraphStyle(
        name="ReportBody", fontName="ArialAudit", fontSize=9.3,
        leading=13.8, textColor=INK, spaceAfter=6,
    )
)
styles.add(
    ParagraphStyle(
        name="ReportSmall", fontName="ArialAudit", fontSize=8,
        leading=11.2, textColor=MUTED, spaceAfter=4,
    )
)
styles.add(
    ParagraphStyle(
        name="ReportCell", fontName="ArialAudit", fontSize=8.2,
        leading=11.4, textColor=INK,
    )
)
styles.add(
    ParagraphStyle(
        name="ReportCellBold", parent=styles["ReportCell"],
        fontName="ArialAudit-Bold",
    )
)
styles.add(
    ParagraphStyle(
        name="ReportHeaderCell", parent=styles["ReportCell"],
        fontName="ArialAudit-Bold", textColor=colors.white,
    )
)
styles.add(
    ParagraphStyle(
        name="ReportHero", fontName="ArialAudit-Bold", fontSize=27,
        leading=33, textColor=colors.white, spaceAfter=9,
    )
)
styles.add(
    ParagraphStyle(
        name="ReportHeroSmall", fontName="ArialAudit", fontSize=10,
        leading=14, textColor=colors.HexColor("#DBEAFE"),
    )
)
styles.add(
    ParagraphStyle(
        name="ReportIssue", fontName="CourierAudit", fontSize=8.5,
        leading=12.0, textColor=INK,
    )
)


def p(value: str, style: str = "ReportBody") -> Paragraph:
    return Paragraph(value, styles[style])


def section(title: str) -> Paragraph:
    return p(escape(title), "ReportH1")


def cell(value: str, bold: bool = False) -> Paragraph:
    return p(escape(value), "ReportCellBold" if bold else "ReportCell")


def headcell(value: str) -> Paragraph:
    return p(escape(value), "ReportHeaderCell")


def simple_table(rows: list[list], widths: list[float], header: bool = True) -> Table:
    table = Table(rows, colWidths=widths, repeatRows=1 if header else 0, hAlign="LEFT")
    commands = [
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 9),
        ("RIGHTPADDING", (0, 0), (-1, -1), 9),
        ("TOPPADDING", (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
        ("LINEBELOW", (0, 0), (-1, 0), 0.7, HAIRLINE),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, PAPER_TINT]),
        ("LINEBELOW", (0, -1), (-1, -1), 0.55, HAIRLINE),
    ]
    if header:
        commands += [
            ("BACKGROUND", (0, 0), (-1, 0), NAVY),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ]
    table.setStyle(TableStyle(commands))
    return table


class SeverityChip(Flowable):
    def __init__(self, text: str = "MÉDIA", color=MEDIUM):
        super().__init__()
        self.width, self.height = 51, 18
        self.text, self.color = text, color

    def draw(self) -> None:
        c = self.canv
        c.setFillColor(self.color)
        c.roundRect(0, 0, self.width, self.height, 6, stroke=0, fill=1)
        c.setFillColor(colors.white)
        c.setFont("ArialAudit-Bold", 7.1)
        c.drawCentredString(self.width / 2, 6.1, self.text)


class Charts(Flowable):
    """Rosca e barras feitas de primitivas PDF; não incluem bitmap."""

    def __init__(self):
        super().__init__()
        self.width = INNER_W
        self.height = 218

    def draw(self) -> None:
        c = self.canv
        c.setFillColor(PAPER_TINT)
        c.setStrokeColor(HAIRLINE)
        c.roundRect(0, 0, self.width, self.height, 12, stroke=1, fill=1)

        c.setFillColor(INK)
        c.setFont("ArialAudit-Bold", 9.3)
        c.drawString(18, self.height - 24, "POR SEVERIDADE")
        c.drawString(208, self.height - 24, "POR CATEGORIA ADAPTADA")

        # Todos os 2 achados são médios: um anel completo representa 100%.
        cx, cy, radius = 94, 109, 52
        c.setStrokeColor(MEDIUM)
        c.setLineWidth(19)
        c.circle(cx, cy, radius, fill=0, stroke=1)
        c.setFillColor(INK)
        c.setFont("ArialAudit-Bold", 26)
        c.drawCentredString(cx, cy - 1, "2")
        c.setFillColor(MUTED)
        c.setFont("ArialAudit", 8)
        c.drawCentredString(cx, cy - 16, "achados")
        c.setFillColor(MEDIUM)
        c.circle(29, 23, 4, stroke=0, fill=1)
        c.setFillColor(INK)
        c.setFont("ArialAudit", 8)
        c.drawString(39, 20, "Média  2 (100%)")

        labels = [
            ("1 · Isolamento local", 0),
            ("2 · Ações privilegiadas", 2),
            ("3 · Identidade / posse", 0),
            ("4 · Segredos", 0),
            ("5 · HTML / injeção", 0),
        ]
        x, bar_x, bar_w = 208, 358, 84
        for i, (label, count) in enumerate(labels):
            y = 166 - i * 30
            c.setFillColor(INK)
            c.setFont("ArialAudit", 7.5)
            c.drawString(x, y, label)
            c.setFillColor(colors.HexColor("#E2E8F0"))
            c.roundRect(bar_x, y - 1, bar_w, 9, 4.5, stroke=0, fill=1)
            if count:
                c.setFillColor(MEDIUM)
                c.roundRect(bar_x, y - 1, bar_w * count / 2, 9, 4.5, stroke=0, fill=1)
            c.setFillColor(INK)
            c.setFont("ArialAudit-Bold", 8)
            c.drawRightString(self.width - 18, y, str(count))


ISSUE_1 = """--- ISSUE 1 ---
# [Segurança] Confirmar SIGKILL ao escalar encerramento pelo aviso

Labels sugeridas: `security`, `medium`

## Problema e condição de exploração
Após uma tentativa de SIGTERM, o CoreScope mostra um aviso se o processo
continuar ativo. O botão “Forçar encerramento” desse aviso envia SIGKILL
com um clique. Ele chama `signal` diretamente, sem usar `requestKill`,
embora o contrato da UI diga que SIGKILL sempre exige confirmação.
Condição: o processo precisa sobreviver ao SIGTERM e o usuário precisa
clicar nesse aviso. O núcleo ainda revalida a identidade do processo.

## Evidência
`native/Design.swift:407-410`:
```swift
if !f.survivors.isEmpty {
  Button(L("Forçar encerramento")) {
    monitor.signal(f.survivors, force: true)
  }.buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
}
```
`native/Models.swift:659-672` direciona SIGKILL a `pendingKill`;
`native/Models.swift:674-705` envia o sinal imediatamente em `signal`.

## Impacto
O usuário pode perder trabalho não salvo de um processo que ignorou
SIGTERM sem ver a confirmação e o aviso específico de SIGKILL.

## Sugestão de correção
Encaminhar a escalada do aviso ao mesmo modal de confirmação usado pela
ação Forçar da janela. Mostrar o nome/PID dos sobreviventes e que
SIGKILL encerra imediatamente com perda de trabalho não salvo.

## Critérios de aceite
- [ ] O clique no aviso abre confirmação e não envia SIGKILL ainda.
- [ ] O modal identifica os sobreviventes e explica a perda possível.
- [ ] Cancelar não chama `cs_signal`; confirmar chama apenas para os
      sobreviventes elegíveis.
- [ ] Teste automatizado cobre a rota do aviso sem sinalizar processos
      reais; a validação de identidade no núcleo continua ativa.
--- FIM ISSUE 1 ---"""

ISSUE_2 = """--- ISSUE 2 ---
# [Segurança] Proteger a ação Encerrar de notificações de processo

Labels sugeridas: `security`, `medium`

## Problema e condições de exploração
A ação “Encerrar” de uma notificação usa somente `.destructive`.
O SDK distingue essa marca visual de `.authenticationRequired`, que
exige desbloqueio antes de executar. Quando a ação chega ao delegado,
o código envia SIGTERM sem verificar novamente se o usuário desligou
as notificações/ações de processo. Desligar a opção só grava o toggle;
um aviso entregue antes disso pode continuar acionável.
Condições: aviso “Novo possível órfão” (`notifyOrphans`) previamente
ativado e permissão do macOS. A tela bloqueada exige que o sistema mostre a ação
nesse estado e alguém com acesso físico a escolha; isso não foi testado
fisicamente. O caminho do aviso antigo exige clicar depois de desligar.
O núcleo ainda revalida a identidade e o UID antes do SIGTERM.

## Evidência
`native/Notifier.swift:31-35`:
```swift
let kill = UNNotificationAction(
  identifier: Self.terminate, title: L("Encerrar"), options: [.destructive])
```
`native/Notifier.swift:141-165` encaminha a resposta a `terminate(id)`
e `monitor.signal([proc], force: false)` sem conferir preferências.
`native/PreferencesView.swift:241-247` não revoga avisos ao desligar.
`UNNotificationAction.h:16-20` define autenticação e marca destrutiva
como opções diferentes.

## Impacto
Uma ação de notificação pode pedir o encerramento de um processo após
a opção ser desligada. Conforme a política de exibição do macOS, pode
também ser escolhida na tela bloqueada sem exigência explícita de
desbloqueio. Trata-se de SIGTERM, não SIGKILL.

## Sugestão de correção
Registrar a ação com `.authenticationRequired` além de `.destructive`.
Revalidar `notifyOrphans` no delegado imediatamente antes do
sinal. Ao desligar, remover notificações de processo pendentes e
entregues; para avisos antigos, rejeitar a resposta no delegado.

## Critérios de aceite
- [ ] A ação requer desbloqueio quando apresentada na tela bloqueada.
- [ ] Resposta de aviso antigo após desativação não chama `cs_signal`.
- [ ] Desligar “Novo possível órfão” remove seus avisos pendentes/entregues.
- [ ] Testes cobrem o toggle e uma resposta atrasada com sinal simulado.
- [ ] Teste manual no macOS confirma a apresentação na tela bloqueada.
--- FIM ISSUE 2 ---"""


def on_page(canvas, doc) -> None:
    canvas.saveState()
    canvas.setStrokeColor(HAIRLINE)
    canvas.setLineWidth(0.55)
    canvas.line(MARGIN, PAGE_H - 17 * mm, PAGE_W - MARGIN, PAGE_H - 17 * mm)
    canvas.setFont("ArialAudit-Bold", 7.4)
    canvas.setFillColor(MUTED)
    canvas.drawString(MARGIN, PAGE_H - 13.8 * mm, "CORESCOPE  /  AUDITORIA DE SEGURANÇA")
    canvas.setStrokeColor(HAIRLINE)
    canvas.line(MARGIN, 17 * mm, PAGE_W - MARGIN, 17 * mm)
    canvas.setFont("ArialAudit", 7.2)
    canvas.drawString(MARGIN, 12.5 * mm, "17 OUT 2026   ·   HEAD d2ad0ff")
    canvas.drawRightString(PAGE_W - MARGIN, 12.5 * mm, f"PÁGINA {doc.page}")
    canvas.restoreState()


def cover(story: list) -> None:
    story.append(Spacer(1, 11 * mm))
    hero = Table(
        [[
            p("AUDITORIA DE CÓDIGO  /  17 DE OUTUBRO DE 2026", "ReportHeroSmall"),
        ], [
            p("Relatório de Auditoria de Segurança — CoreScope", "ReportHero"),
        ], [
            p("Revisão estática do commit d2ad0ff · aplicativo pessoal para macOS", "ReportHeroSmall"),
        ]],
        colWidths=[INNER_W],
    )
    hero.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), NAVY),
        ("LEFTPADDING", (0, 0), (-1, -1), 21),
        ("RIGHTPADDING", (0, 0), (-1, -1), 21),
        ("TOPPADDING", (0, 0), (-1, 0), 22),
        ("BOTTOMPADDING", (0, -1), (-1, -1), 24),
        ("TOPPADDING", (0, 1), (-1, 1), 14),
        ("BOTTOMPADDING", (0, 1), (-1, 1), 18),
    ]))
    story.append(hero)
    story += [Spacer(1, 15 * mm), section("Escopo auditado")]
    story.append(p(
        "Aplicativo SwiftUI/AppKit local; núcleo Rust/C por FFI; persistência SQLite opcional; "
        "cliente Docker por socket Unix; subprocesso Codex CLI e statusline Claude opt-in; "
        "scripts de build, CI e release no GitHub Actions. Não há servidor HTTP próprio, "
        "rotas web, login, tenants, frontend HTML ou ORM."
    ))
    story.append(p(
        "Um delta concorrente em native/Agents.swift, native/Localization.swift e "
        "native/CodexThreads.swift foi conferido separadamente e não acrescentou achado "
        "confirmado. As referências de linha dos achados usam o HEAD d2ad0ff.",
        "ReportSmall",
    ))
    story.append(section("Nota metodológica"))
    story.append(p(
        "As cinco categorias solicitadas foram mapeadas à arquitetura real. Isolamento de "
        "tenant virou separação por UID e arquivos locais; autorização de backend virou "
        "proteção nas ações SwiftUI/notifications e na fronteira FFI; IDOR virou validação "
        "de identidades de processo e contêiner; segredos cobriram código, Git, app, "
        "distribuição e CI; XSS cobriu superfícies HTML/URL existentes. Foram reportados "
        "somente dois riscos verificados no código, sem forçar cinco achados."
    ))
    note = Table([[p(
        "<b>Limite:</b> as condições dependentes da tela bloqueada e de preferências de "
        "notificações não foram reproduzidas fisicamente; a evidência é o fluxo de código e "
        "o contrato do SDK. Nenhum sinal foi enviado a processos reais durante a auditoria.",
        "ReportSmall",
    )]], colWidths=[INNER_W])
    note.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), PAPER_TINT),
        ("BOX", (0, 0), (-1, -1), 0.6, HAIRLINE),
        ("LEFTPADDING", (0, 0), (-1, -1), 11),
        ("RIGHTPADDING", (0, 0), (-1, -1), 11),
        ("TOPPADDING", (0, 0), (-1, -1), 9),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 9),
    ]))
    story += [Spacer(1, 5 * mm), note, PageBreak()]


def summary(story: list) -> None:
    story += [section("Resumo executivo"), p(
        "<b>2 achados de severidade média.</b> Ambos tratam de decisões de encerramento "
        "de processos na interface. O núcleo preserva checagens de UID, PID, instante de "
        "início e caminho do executável imediatamente antes de enviar o sinal."
    )]
    severity = [
        ("Crítica", "0", CRITICAL), ("Alta", "0", HIGH),
        ("Média", "2", MEDIUM), ("Baixa", "0", LOW),
    ]
    tiles = []
    for label, number, color in severity:
        tiles.append(p(f'<font color="{color.hexval()}"><b>{number}</b></font><br/>{label}', "ReportBody"))
    t = Table([tiles], colWidths=[INNER_W / 4] * 4)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), PAPER_TINT),
        ("BOX", (0, 0), (-1, -1), 0.7, HAIRLINE),
        ("INNERGRID", (0, 0), (-1, -1), 0.5, HAIRLINE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 13),
        ("TOPPADDING", (0, 0), (-1, -1), 12),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
    ]))
    story += [t, Spacer(1, 6 * mm), Charts(), Spacer(1, 6 * mm)]
    story.append(p(
        "<b>Leitura:</b> os dois achados se concentram na categoria 2 adaptada às ações "
        "privilegiadas de uma GUI local. A1 permite escalar de SIGTERM para SIGKILL sem novo "
        "diálogo no aviso; A2 mantém um caminho de SIGTERM por notificação sem revalidar "
        "a preferência e sem exigir desbloqueio pela opção específica do SDK."
    ))
    story += [section("Critério de severidade"), p(
        "Média porque há ação explícita do usuário ou acesso físico condicionado, e as "
        "barreiras do núcleo limitam o alvo ao UID e à identidade revalidada. O impacto "
        "ainda inclui interrupção de processos e, em A1, perda de trabalho não salvo. "
        "Não foi demonstrada execução remota, escalada de privilégio do macOS ou acesso "
        "a processos de outro usuário."
    ), PageBreak()]


def coverage(story: list) -> None:
    story.append(section("Cobertura das cinco categorias"))
    rows = [
        [headcell("Categoria"), headcell("Equivalente nesta stack"), headcell("Resultado e evidência")],
        [cell("1 · Banco sem tranca", True), cell("Isolamento local por UID e diretórios do usuário; sem tenant/RLS."),
         cell("Sem achado. core/src/lib.rs:585-619 e 1249-1269; histórico SQLite local opcional.")],
        [cell("2 · Permissão no navegador", True), cell("Confirmação e preferências da GUI/notifications antes de sinalizar."),
         cell("A1 e A2. native/Design.swift:407-410; native/Notifier.swift:31-35 e 141-165.")],
        [cell("3 · IDOR", True), cell("Identidade de processo e contêiner; não há handlers HTTP próprios."),
         cell("Sem achado. lib.rs:1249-1269; containers.rs:415-458.")],
        [cell("4 · Chaves expostas", True), cell("Código, histórico Git, app/distribuição e workflows."),
         cell("Sem candidato reportável na varredura gitleaks; token CI dinâmico em release.yml:85.")],
        [cell("5 · Inputs/XSS", True), cell("SwiftUI Text/URLs; sem WebView, HTML ou templates de e-mail."),
         cell("Sem achado. deep link validado em native/Agents.swift:42-45; porta UInt16 em Design.swift:379-386.")],
    ]
    story.append(simple_table(rows, [101, 177, INNER_W - 278]))
    story += [Spacer(1, 6 * mm), section("Pontos fortes verificados")]
    strengths = [
        ("Sinalização restrita", "UID, PID, início, caminho e serviços protegidos são checados; duas leituras da identidade precedem o sinal.", "core/src/lib.rs:585-619, 1249-1269"),
        ("Contêiner sem ID ambíguo", "ID hexadecimal e ação permitida são validados; o contêiner deve aparecer exatamente uma vez entre sockets resolvidos.", "core/src/containers.rs:76-95, 415-458"),
        ("Consultas locais parametrizadas", "SQLite usa sqlite3_bind_* para valores externos; a consulta de histórico tem ordem escolhida em enumeração fixa.", "core/src/sqlite.rs:138-162; history.rs:550-580"),
        ("Entradas nativas delimitadas", "Os oito pontos FFI exportados foram percorridos; ponteiros e operações são validados antes da execução.", "core/src/lib.rs:1290-1432"),
        ("Credenciais de CI", "Checkouts desativam persistência de credenciais; release usa token transitório do GitHub Actions.", ".github/workflows/ci.yml:22-24; release.yml:28-31, 83-85"),
    ]
    for title, detail, source in strengths:
        story.append(KeepTogether([
            p(f'<font color="#059669"><b>● {escape(title)}</b></font>  {escape(detail)}'),
            p(escape(source), "ReportSmall"),
        ]))
    story += [PageBreak()]


def findings(story: list) -> None:
    story.append(section("Pontos fracos e achados detalhados"))
    story.append(p(
        "Os dois riscos estão na categoria 2 adaptada: a decisão visível ao usuário pode "
        "pular uma confirmação ou permanecer acionável após uma preferência ser desligada. "
        "A proteção do núcleo reduz o alcance, mas não substitui essa decisão da interface."
    ))
    story.append(p("2 · Ações privilegiadas em interface local", "ReportH2"))
    rows = [
        [headcell("Severidade"), headcell("Arquivo:linha"), headcell("Descrição e condição")],
        [SeverityChip(), p("<b>A1</b><br/>native/Design.swift:407-410<br/>native/Models.swift:659-672, 674-705", "ReportCell"),
         cell("Sobrevivente de SIGTERM + clique no aviso: SIGKILL é enviado diretamente, sem nova confirmação/aviso de perda de trabalho. O núcleo revalida a identidade.")],
        [SeverityChip(), p("<b>A2</b><br/>native/Notifier.swift:31-35, 141-165<br/>native/PreferencesView.swift:241-247", "ReportCell"),
         cell("Ação de notificação usa .destructive sem .authenticationRequired; resposta antiga após desativação não revalida a preferência. Tela bloqueada depende da exibição pelo macOS e não foi testada fisicamente.")],
    ]
    story.append(simple_table(rows, [70, 170, INNER_W - 240]))
    story += [Spacer(1, 5 * mm)]
    story.append(p(
        "<b>Nota de precisão:</b> o botão “Forçar (SIGKILL)” que já está dentro do "
        "diálogo de SIGTERM em native/Design.swift:447-448 é parte do diálogo; não foi "
        "contado como achado. O texto de risco do diálogo está em native/Models.swift:511-515."
    , "ReportSmall"))
    story += [section("Recomendações priorizadas")]
    recommendations = [
        ("P1", "A1 · Encaminhar o botão do aviso a confirmação de SIGKILL, com sobreviventes e perda possível explicitados."),
        ("P1", "A2 · Exigir autenticação na ação de notificação, conferir a preferência ao receber resposta e retirar avisos de processo quando desligada."),
        ("P2", "Adicionar testes para escalada do aviso, resposta antiga de notificação e cancelamento, usando sinais simulados."),
        ("P3", "Conferir manualmente a apresentação da ação na tela bloqueada nas configurações de notificação oferecidas pelo macOS."),
    ]
    for priority, item in recommendations:
        story.append(p(f"<b>{priority}</b>  {escape(item)}"))
    story += [Spacer(1, 3 * mm), p(
        "A tabela identifica os locais de correção; as issues abaixo trazem trechos literais, "
        "impacto e critérios verificáveis para abrir no GitHub.", "ReportSmall"
    ), PageBreak()]


def issues(story: list) -> None:
    story.append(section("ISSUES PARA O GITHUB"))
    story.append(p(
        "O Markdown completo entre os delimitadores está reproduzido abaixo e também em "
        "ISSUES.md ao lado deste PDF, pronto para copiar. Cada issue corresponde a um "
        "achado verificado; os dois subcasos de notificação estão agrupados em A2.",
        "ReportSmall",
    ))
    for index, text in enumerate([ISSUE_1, ISSUE_2], start=1):
        if index > 1:
            story.append(PageBreak())
        story.append(p(f"Issue {index}  ·  severidade média", "ReportH2"))
        block = Table(
            [[Preformatted(text, styles["ReportIssue"], maxLineLength=86, splitChars=" ")]],
            colWidths=[INNER_W],
        )
        block.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, -1), PAPER_TINT),
            ("BOX", (0, 0), (-1, -1), 0.8, HAIRLINE),
            ("LINEBEFORE", (0, 0), (0, -1), 3, MEDIUM),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 13),
            ("RIGHTPADDING", (0, 0), (-1, -1), 11),
            ("TOPPADDING", (0, 0), (-1, -1), 11),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 11),
        ]))
        story.append(block)


def main() -> None:
    ISSUES_OUT.write_text(ISSUE_1 + "\n\n" + ISSUE_2 + "\n", encoding="utf-8")
    doc = BaseDocTemplate(
        str(OUT), pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN,
        topMargin=22 * mm, bottomMargin=22 * mm,
        title="Relatório de Auditoria de Segurança — CoreScope",
        author="Auditoria de código CoreScope",
        subject="Achados verificados no commit d2ad0ff em 17/10/2026",
    )
    frame = Frame(
        MARGIN, 22 * mm, INNER_W, PAGE_H - 44 * mm,
        leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0,
    )
    doc.addPageTemplates(PageTemplate(id="report", frames=[frame], onPage=on_page))
    story: list = []
    cover(story)
    summary(story)
    coverage(story)
    findings(story)
    issues(story)
    doc.build(story)
    print(f"Gerados: {OUT} e {ISSUES_OUT}")


if __name__ == "__main__":
    main()
