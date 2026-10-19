# Controladores de ambiente

*[Read in English](ENVIRONMENT-CONTROLLER.md)*

Um projeto pode entregar o ambiente local (arquivos Compose, imagens, quais apps estão ligados, modo
dev ou build de cada componente, setup, backups) a um **controlador**: um comando do próprio projeto,
como `bin/eco`. O CoreScope continua sendo a interface: executa os comandos do controlador, mostra
progresso, logs e resultado, lê o estado real e distingue *desligado* de *em falha*, *externo* e
*mantido para outro app*. Ele nunca aprende o grafo de dependências do projeto e nunca dispara uma
segunda operação Docker nos recursos do controlador.

Tudo aqui é opcional. Um `.corescope.yml` sem estas chaves funciona exatamente como antes.

O exemplo de YAML, a tabela de estados, o formato JSON do status e os limites estão na
[versão em inglês](ENVIRONMENT-CONTROLLER.md) (os nomes de campos são os mesmos). Resumo:

## `.corescope.yml`

Tudo fica sob uma chave `environment:` (exemplo completo na versão em inglês):

- `environment.status: {run, timeout_seconds}` — comando somente leitura que imprime o JSON formato 1.
- `environment.apps.<app>` — um app do controlador: `title`, `modes` (formas de subir, uma por
  vez: `dev: bin/eco up arena --web dev`), `down` (obrigatório com `modes`; derruba só este app),
  `containers` (só observados) e `actions`. Um app sem modos é só um grupo de ações (memória dos
  agentes, por exemplo).
- `environment.actions` — ações do ambiente inteiro (init, doctor…).
- Ação: `{run, description, timeout_minutes, confirm, preview, heavy, kind}`; `kind` (setup, run,
  diagnostics, data, stop, other) ordena a lista e, sem ele, vem do nome.
- `services[].profiles: [perfis]`, `services[].app: app` e `services[].component: nome` — o check
  é exigido enquanto algo que precisa dele está ligado.

As outras chaves (`profiles`, `ports`, `services`, `logs`, `agents`) funcionam como antes; um arquivo
sem `environment` se comporta exatamente como antes.

## O que o CoreScope faz

- Na página Perfis, cada app é uma linha: estado numa coluna fixa, menu **Iniciar** com os modos e
  **Parar**; aberta, mostra os modos, os componentes, os contêineres observados e as ações por tipo.
  Iniciar outro modo troca o atual. Para o MCP, cada modo é o perfil `projeto/app:modo`.
- **Iniciar** um modo só executa o comando dele; nenhum contêiner é iniciado pelo
  CoreScope, então não existe corrida com o `up` do controlador. Comando ainda rodando = operação em
  andamento (*iniciando*). Os comandos devem **terminar** depois de verificar o que subiram;
  watchers (Vite, Air) ficam dentro do controlador.
- Saída 0 não significa saudável: a saúde vem do status, dos contêineres observados (parado,
  ausente ou `unhealthy` → degradado) e das saídas (≠ 0 ou cancelado → *falhou*).
- **Parar** envia SIGTERM a uma operação ainda em andamento e executa o `down` do app (2 min). Nunca para contêineres e nunca roda comandos de outro perfil.
- Uma operação por ambiente (arquivo do projeto) por vez: início/parada de perfil controlador ou
  ação são recusados enquanto outra roda. O controlador deve ter a própria trava (terminais não
  passam pelo CoreScope).
- Checks vinculados: não exigido e sem resposta → *não está rodando* (neutro); não exigido e
  respondendo → *fora do CoreScope* (externo, não adotado); exigido → no ar / com erro / fora do ar;
  operação em andamento, componente `starting` (o controlador marca assim o que está mexendo) ou até 2 min após iniciar →
  *iniciando*; status falhou, expirou, inválido, desatualizado ou sem o componente → *desconhecido*,
  nunca no ar nem desligado. Só *fora do ar* alerta e conta na disponibilidade. Porta aberta (proxy
  do Herd na 443) não conta.
- O status roda a cada 30 s por projeto com uma janela ou o painel do CoreScope aberto ou uma
  operação em andamento (a cada 2 min fora disso), após cada operação e sob demanda, um por vez
  (coalescido), com timeout; via `/bin/sh` com o ambiente do shell de login lido uma vez (sem abrir
  um shell interativo a cada leitura); lê até 256 KB do stdout. Leitura pedida há mais de 6 min, ou
  com `collected_at` mais de 2 min antes do pedido, é desatualizada. A última leitura válida continua visível, marcada como
  antiga.
- Docker desligado não é falha: se o controlador não leu nenhum componente esperado (todos
  `unknown`) e nenhum motor de contêineres responde ao CoreScope, o ambiente conta como desligado
  (apps *desligados*, checks neutros, uma linha cinza no lugar do erro de conexão).
- Reconciliação: se um status novo (pedido depois da última operação, sem nada rodando) diz que o
  app de um perfil iniciado pelo CoreScope não está mais selecionado, o CoreScope esquece o início
  sem executar nada. App selecionado no terminal aparece como *mudou fora do CoreScope*, sem adoção.
- Ações: sessão e log próprios, fora da main thread, `timeout_minutes` (padrão 10, até 1440; SIGTERM
  e SIGKILL 5 s depois). `heavy: true` roda `corescope wait .` antes. `confirm: true` roda `preview`
  (somente leitura, 20 s, 8 KB), mostra a saída como está e só executa após *Executar* explícito; a
  ação recebe `CORESCOPE_CONFIRMED=1` e `CORESCOPE_PREVIEW_SHA256` — **o controlador deve
  replanejar e recusar se o hash mudou**. Iniciar perfil nunca executa ação.
- Resultado: `succeeded`, `failed`, `cancelled`, `timed_out` ou `interrupted`. Cancelar ou estourar
  o tempo só encerra o comando que o CoreScope iniciou: uma operação já entregue a outro processo
  pode continuar — o CoreScope relê o status, e o controlador deve informá-la em `busy`.
- Artefato: imprima `CORESCOPE_ARTIFACT=<caminho>` numa linha própria. Vale a última, só com saída 0
  e se o arquivo existir; o CoreScope oferece *Mostrar no Finder* e nunca abre nem interpreta o
  arquivo.
- MCP: `list_profiles`, `list_services`, `environment_status`, `list_actions`, `run_action`
  (destrutiva; com `confirm`, a primeira chamada devolve a prévia e `needs_confirmation`),
  `cancel_action` (destrutiva).

## Para quem implementar o controlador

- `up`/`down`/`switch` fazem a operação inteira, verificam e só então saem com 0; senão, saem ≠ 0
  com mensagem legível. `down <app>` para só o que nenhum app selecionado ainda usa e nunca para
  recursos `external`.
- Trava para operações concorrentes (terminal e CoreScope ao mesmo tempo), informada em `busy`.
- Troca dev/build é uma operação só, termina com uma variante por componente e preserva volumes.
- `status --json` não sobe, não compila nem baixa nada; responde bem abaixo de 5 s.
- Saída do status é dado: nada de credenciais, tokens, strings de conexão ou conteúdo de memórias.
  Para a memória dos agentes, três sinais separados: API responde, cliente MCP inicializa, consulta
  real — esta só numa ação de diagnóstico.
- Backup é leitura; restauração só contra destino nomeado explicitamente, com
  `CORESCOPE_CONFIRMED=1` e `CORESCOPE_PREVIEW_SHA256` conferido; a prévia imprime arquivo, origem,
  data e destino.
- Sem caminhos pessoais: use a pasta do projeto e configuração local não versionada.

## Limitações

As mesmas da [versão em inglês](ENVIRONMENT-CONTROLLER.md#limitations): integração real só
comprovada quando os comandos do projeto existirem; o status abre um shell de login a cada 30 s por
projeto; contêineres por nome (labels Compose não implementados); sem controles de modo/seleção nem
ações parametrizadas na interface; comando iniciado antes de reiniciar o CoreScope só é cancelado se
o mesmo processo ainda existir.
