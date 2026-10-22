# Spec: gate de capacidade por admissão, não por bloqueio

## Objetivo

O gate de capacidade existe para que várias sessões de agentes, no mesmo Mac, não sobrecarreguem a máquina: cada ação que pode gerar gargalo (suíte de testes, build, análise estática, subir containers) deve rodar no momento certo, sem derrubar ambientes nem disputar recursos com outras sessões.

Hoje ele cumpre isso **segurando** o comando dentro do hook até haver folga. Isso troca um problema por outro: o agente e o processo ficam parados sem saber por quê, às vezes pelo limite inteiro, e ao liberar vários comandos começam juntos. Esta spec muda o gate de "segurar até poder" para "decidir na hora e orientar": o agente consulta antes, recebe uma resposta rápida e clara, aguarda do jeito certo e verifica de novo antes de executar.

## Incidente que motiva a mudança (2026-10-22)

- Mac com 16 GB, CPU entre 10% e 16%, pressão de memória normal.
- VM do OrbStack limitada a 4 GB, com 14% livre (limite da regra: 15%). Ocupação: MySQL de teste 1,4 GB, outro MySQL 263 MB, Redis 180 MB, Hindsight 151 MB.
- Um `go test ./internal/http/` que roda só no Mac (usa miniredis, não toca container) ficou preso. Também ficou preso um `php artisan test` de outra sessão.
- O motivo só existia em `~/Library/Application Support/CoreScope/gates/<pid>.json` e no stderr do hook, que o Claude Code não mostra. Para o usuário e para o agente, o comando estava travado.
- O usuário interrompeu as chamadas várias vezes; uma sessão terminou no meio da execução. Cada comando teria esperado os 30 minutos de `max_wait_minutes` e depois rodado mesmo assim.
- A condição não podia mudar sozinha: a memória da VM só libera quando containers param ou encolhem, então a espera era pura perda de tempo.

## Problemas atuais

| # | Problema | Onde |
| --- | --- | --- |
| P1 | O hook dorme até `max_wait_minutes` (até 55 min); a chamada do agente fica parada e o usuário não vê nada | `gate()` e `wait_for_room()` em `core/src/bin/corescope/main.rs` |
| P2 | O motivo da espera sai por `eprintln!` e num arquivo; não chega ao agente nem ao usuário | `gate()` |
| P3 | Todo comando pesado é checado contra CPU, memória do Mac **e** memória da VM, mesmo que não use containers | `blockers()` em `core/src/capacity.rs`; `CapacitySpec` em `core/src/projectconfig.rs` |
| P4 | Bloqueios que não se resolvem esperando (VM ocupada por containers parados no lugar) são tratados como espera | `blockers()` / `wait_for_room()` |
| P5 | Cada comando em espera checa sozinho; quando a máquina libera, todos começam ao mesmo tempo e sobrecarregam de novo (já anotado no README como "A queue for the capacity gate") | `wait_for_room()` |
| P6 | Depois do limite, o comando roda "mesmo assim", sem a máquina ter folga: o pior dos dois mundos (esperou e ainda sobrecarrega) | `gate()` |

## Princípios

1. **Decidir rápido, nunca dormir no hook.** O hook responde em poucos segundos: libera ou recusa com orientação. A espera, quando houver, é do agente, de forma explícita e visível.
2. **Checar o recurso que o comando usa.** Comando que roda no Mac olha CPU e memória do Mac; comando que depende de containers olha também a VM.
3. **Dizer sempre o porquê e o que fazer.** Toda recusa traz o motivo, os números, uma estimativa e a ação recomendada.
4. **Não esperar o que não vai mudar.** Se a condição só muda com uma ação (parar container, aumentar a VM), dizer isso na hora em vez de esperar.
5. **Ordem justa e sem estouro na liberação.** Comandos pesados entram em fila e são admitidos de forma escalonada, não todos ao mesmo tempo.
6. **Falhar aberto.** Se o CoreScope não responder, o comando segue; o gate nunca pode ser o motivo de um agente ficar travado.

## Proposta

### 1. Hook de admissão (substitui a espera dentro do hook)

O `corescope gate` deixa de chamar `wait_for_room()` com o limite do projeto. Ele faz uma leitura (amostra de CPU em até ~1 s), decide e responde:

- **Liberado**: sai com código 0, sem saída; o comando roda.
- **Adiado**: responde ao Claude Code com a decisão de recusa do PreToolUse e um motivo legível pelo modelo, por exemplo:

  > CoreScope adiou `php artisan test`: a VM do OrbStack tem 14% de memória livre (limite 15%); os maiores consumidores são TO--mysql (1,4 GB) e leilotech-mysql-1 (263 MB). Esperar não resolve: pare um container que não está em uso ou aumente a memória da VM. Depois chame `wait_for_capacity` (ou `reserve_capacity`) e tente de novo.

  Para espera que se resolve sozinha (CPU alta), o texto traz a estimativa e a instrução de chamar `wait_for_capacity` antes de repetir.

- **Codex e outros agentes** recebem a mesma informação no formato que o hook deles aceita; onde não houver recusa estruturada, o hook imprime o motivo de forma que apareça para o agente e libera (falha aberta), registrando o evento.

O tempo máximo do hook passa a ser fixo e curto (proposta: 5 s). `max_wait_minutes` continua valendo, mas só para a espera explícita via MCP.

### 2. Recurso por comando

`heavy_commands` aceita, além de strings, entradas com o que o comando usa:

```yaml
agents:
  wait_for_capacity:
    cpu_below: 70
    memory: normal
    container_memory_free: 15
    max_wait_minutes: 30
    heavy_commands:
      - npm run build                      # string: só Mac (CPU e memória)
      - command: php artisan test
        uses: [cpu, memory, containers]    # também checa a VM
        weight: 3
      - command: go test
        uses: [cpu, memory]
        weight: 2
```

- `uses`: `cpu`, `memory` (do Mac) e `containers` (memória da VM). Entrada em string equivale a `[cpu, memory]`.
- `weight`: peso aproximado do comando, usado pela fila (item 3). Padrão 1.
- Compatibilidade: arquivos atuais continuam válidos. Comandos da lista padrão que normalmente sobem ou usam containers (`docker compose up`, suítes que dependem de banco) podem vir marcados com `containers` por padrão; isso deve ficar documentado.
- Detecção opcional: comandos Go cujos pacotes importam `testcontainers` podem ser tratados como `containers` mesmo sem marcação; avaliar o custo antes de implementar.

### 3. Fila de admissão e reservas

Para evitar o estouro quando a máquina libera (P5):

- Novo par de tools MCP: `reserve_capacity` (pede uma vaga para um comando, com peso e recursos; responde `granted` ou a posição na fila e a estimativa) e `release_capacity` (devolve a vaga). A reserva tem validade curta (proposta: 2 min sem uso, renovada enquanto o processo vive) para não prender vagas de sessões que morreram.
- O hook de admissão consulta a mesma fila: um comando com reserva válida passa direto; sem reserva, entra na fila e é adiado se houver alguém na frente.
- Admissão escalonada: quando há folga, admite o primeiro da fila, espera a leitura refletir a carga nova (alguns segundos) e só então avalia o próximo. Opcionalmente, um teto de comandos pesados simultâneos por máquina, por soma de pesos.
- A fila e as reservas aparecem no app (quem espera, por quê, há quanto tempo, posição) e em `system_capacity`.

### 4. Bloqueios que não se resolvem esperando

`blockers()` passa a classificar cada bloqueio:

- **transitório** (CPU alta, pressão de memória momentânea): vale esperar; a resposta traz estimativa.
- **estrutural** (VM ocupada por containers ociosos, VM menor que a soma dos limites dos containers): esperar não resolve; a resposta diz exatamente o que fazer (quais containers parar, quanto aumentar a VM, comando para isso) e não sugere esperar.

Para o estrutural, o app pode oferecer as ações em um clique (parar container que não pertence a perfil ativo, abrir a configuração de memória da VM).

### 5. Instruções aos agentes

O texto injetado pelo `corescope context --hook` e as descrições das tools MCP passam a ensinar o fluxo:

1. Antes de um comando pesado, chamar `system_capacity` (ou `reserve_capacity`).
2. Se não houver folga transitória, chamar `wait_for_capacity` em ciclos curtos (até 55 s cada) e verificar de novo; não insistir no comando.
3. Se o bloqueio for estrutural, seguir a ação indicada ou avisar o usuário; não esperar.
4. Não rodar comandos pesados em paralelo nem em segundo plano para fugir da fila.
5. Quando a verificação puder rodar fora da máquina (CI), preferir a CI.

### 6. Visibilidade e registro

- Toda decisão do gate (liberado, adiado, motivo, recursos, duração) fica num registro consultável pelo app e por uma tool MCP (por exemplo, `capacity_events`).
- O arquivo em `gates/` continua existindo enquanto houver espera explícita, mas deixa de ser a única fonte de informação.

## Critérios de aceite

1. Com a VM do OrbStack abaixo do limite e o Mac folgado, `go test` (sem `containers`) é liberado imediatamente.
2. Na mesma situação, `php artisan test` (com `containers`) é recusado em até 5 s, e o motivo, com os containers que mais usam memória e a ação recomendada, aparece para o agente no Claude Code.
3. Nenhum hook do gate passa de 5 s, em nenhum cenário.
4. Com CPU acima do limite, o comando é recusado com estimativa; o agente consegue esperar com `wait_for_capacity` e o comando passa na tentativa seguinte quando houver folga.
5. Com três comandos pesados na fila e a máquina liberando, eles são admitidos um de cada vez, com intervalo suficiente para a leitura refletir a carga.
6. Uma reserva de sessão que morreu expira sozinha e não bloqueia a fila.
7. Se o CoreScope não responder, o hook libera o comando e registra a falha.
8. `.corescope.yml` existentes (só strings em `heavy_commands`) continuam funcionando sem alteração.
9. Testes em `core/src/capacity.rs` e no binário cobrem: classificação transitório/estrutural, recursos por comando, ordem da fila, expiração de reserva e o cenário do incidente.

## Fora de escopo

- Limitar CPU ou memória de processos já em execução.
- Mudar automaticamente a memória da VM do OrbStack ou parar containers sem ação do usuário.
- Agendar comandos para horários específicos.

## Perguntas em aberto

- A recusa estruturada do PreToolUse do Claude Code mostra o motivo ao modelo em todos os modos de permissão (inclusive bypass)? Validar antes de depender disso; se não mostrar, usar o canal de contexto adicional do hook.
- Qual intervalo entre admissões evita o estouro sem atrasar demais? Medir com suíte PHP paralela e build Vite.
- Vale um teto global de comandos pesados simultâneos, além da leitura de CPU e memória?
- Como tratar comandos pesados disparados pelos próprios perfis do CoreScope (por exemplo, `make test-env-up`), que hoje não passam pelo hook?

## Estado da implementação

Implementado em `core/src/admission.rs` (fila), `core/src/capacity.rs` (recursos, bloqueios, `advice`), `corescope gate` / `wait` / `capacity-advice` e nas tools MCP. Além do que a spec pedia:

- **Comandos em execução contam.** Um comando admitido fica na fila como *rodando* enquanto vivem os processos que o agente iniciou para ele. Isso permite um teto real (`max_parallel`, por peso, padrão 2) e **um comando pesado por contêiner** (`containers: [...]` em `heavy_commands`): duas suítes no mesmo MySQL foi o que o derrubou.
- **Contêineres por comando.** Cada contêiner listado precisa estar rodando e abaixo de 90% do próprio limite; senão o bloqueio é estrutural, com a ação.
- **`capacity_advice`** analisa a VM e os contêineres do projeto e propõe a regra para revisar.

Respostas às perguntas em aberto:

- **Recusa no Claude Code:** `permissionDecision: "deny"` com `permissionDecisionReason` (exit 0) chega ao modelo. Segundo a documentação, uma recusa de hook bloqueia antes da avaliação de permissões; o modo bypass não está descrito explicitamente. O Codex aceita o mesmo formato. Um hook que estoura o timeout não bloqueia, então a falha é aberta; o timeout instalado passou a ser 10 s.
- **Intervalo entre admissões:** 15 s por unidade de peso, depois da admissão anterior. É um valor inicial; o registro (`capacity_events`) permite ajustar.
- **Teto global:** `max_parallel` (soma de pesos; um comando sozinho sempre roda se houver folga).
- **Comandos dos perfis:** ações de ambiente marcadas `heavy` passam pela fila (`corescope wait --command`). Comandos de perfil ainda não passam; isso ficou no backlog.
