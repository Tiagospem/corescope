--- ISSUE 1 ---
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
--- FIM ISSUE 1 ---

--- ISSUE 2 ---
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
--- FIM ISSUE 2 ---
