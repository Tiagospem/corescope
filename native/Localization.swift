import Foundation

/// Interface language: Portuguese is the source; English and Spanish come from the table below.
/// "system" follows the macOS preferred languages (falls back to English for other languages).
enum Localization {
  static let supported = ["pt", "en", "es"]
  private(set) static var current = resolve()
  static func resolve() -> String {
    let choice = UserDefaults.standard.string(forKey: "language") ?? "system"
    if supported.contains(choice) { return choice }
    for language in Locale.preferredLanguages {
      let code = String(language.prefix(2))
      if supported.contains(code) { return code }
    }
    return "en"
  }
  static func refresh() {
    current = resolve()
    // AppKit's own menus (Edit, Window…) follow AppleLanguages on the next launch.
    let choice = UserDefaults.standard.string(forKey: "language") ?? "system"
    if supported.contains(choice) {
      UserDefaults.standard.set([choice], forKey: "AppleLanguages")
    } else {
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
  }
  /// pt ¦ en ¦ es, one entry per line.
  static let table: [String: (en: String, es: String)] = {
    var out: [String: (en: String, es: String)] = [:]
    for line in entries.split(separator: "\n") {
      let parts = line.components(separatedBy: " ¦ ")
      guard parts.count == 3 else { continue }
      out[parts[0]] = (parts[1], parts[2])
    }
    return out
  }()
}

/// Localized text for a Portuguese source key; `%@` placeholders take `args` in order.
func L(_ key: String, _ args: String...) -> String {
  let entry = Localization.table[key]
  let text: String
  switch Localization.current {
  case "en": text = entry?.en ?? key
  case "es": text = entry?.es ?? key
  default: text = key
  }
  guard !args.isEmpty else { return text }
  return String(format: text, arguments: args.map { $0 as NSString })
}

private let entries = """
  %.0f%% de %@ ¦ %.0f%% of %@ ¦ %.0f%% de %@
  %@ (%@) ignorou o pedido. ¦ %@ (%@) ignored the request. ¦ %@ (%@) ignoró la solicitud.
  %@ continuam ativos. ¦ %@ are still running. ¦ %@ siguen activos.
  %@ de %@ ¦ %@ of %@ ¦ %@ de %@
  %@ encerrado. ¦ %@ terminated. ¦ %@ finalizado.
  %@ livres de %@ ¦ %@ free of %@ ¦ %@ libres de %@
  %@ núcleos ¦ %@ cores ¦ %@ núcleos
  %@ núcleos · térmico %@ ¦ %@ cores · thermal %@ ¦ %@ núcleos · térmico %@
  %@ possíveis órfãos ¦ %@ possible orphans ¦ %@ posibles huérfanos
  %@ proc. ¦ %@ proc. ¦ %@ proc.
  %@ processos compartilham estas portas ¦ %@ processes share these ports ¦ %@ procesos comparten estos puertos
  %@ processos encerrados. ¦ %@ processes terminated. ¦ %@ procesos finalizados.
  %@ processos filhos ¦ %@ child processes ¦ %@ procesos hijos
  %@ processos · %@ servidores · %@ órfãos ¦ %@ processes · %@ servers · %@ orphans ¦ %@ procesos · %@ servidores · %@ huérfanos
  %@ servidores em escuta ¦ %@ listening servers ¦ %@ servidores en escucha
  %@ · CPU %@ · %@ ¦ %@ · CPU %@ · %@ ¦ %@ · CPU %@ · %@
  + %@ servidores ¦ + %@ servers ¦ + %@ servidores
  A cada 10 segundos ¦ Every 10 seconds ¦ Cada 10 segundos
  A cada 2 segundos ¦ Every 2 seconds ¦ Cada 2 segundos
  A cada 3 segundos ¦ Every 3 seconds ¦ Cada 3 segundos
  A cada 5 segundos ¦ Every 5 seconds ¦ Cada 5 segundos
  Abrir CoreScope ¦ Open CoreScope ¦ Abrir CoreScope
  Abrir Terminal aqui ¦ Open Terminal here ¦ Abrir Terminal aquí
  Abrir Terminal no diretório ¦ Open Terminal in folder ¦ Abrir Terminal en la carpeta
  Abrir diretório no Finder ¦ Show folder in Finder ¦ Mostrar carpeta en Finder
  Abrir http://localhost:%@ ¦ Open http://localhost:%@ ¦ Abrir http://localhost:%@
  Abrir no Finder ¦ Open in Finder ¦ Abrir en Finder
  Acessível na rede ¦ Reachable on the network ¦ Accesible en la red
  Acompanhados ¦ Watched ¦ Seguidos
  Acompanhar CPU e memória ¦ Track CPU and memory ¦ Seguir CPU y memoria
  Agente ¦ Agent ¦ Agente
  Agentes ¦ Agents ¦ Agentes
  Aguardando ¦ Waiting ¦ Esperando
  Ajustes ¦ Settings ¦ Ajustes
  Ajustes… ¦ Settings… ¦ Ajustes…
  Antigo ¦ Stale ¦ Antiguo
  Ao vivo ¦ Live ¦ En vivo
  Armazenamento ¦ Storage ¦ Almacenamiento
  Atenção ¦ Warning ¦ Atención
  Ativa + wired + compressor (%@). Pressão de memória: %@. ¦ Active + wired + compressed (%@). Memory pressure: %@. ¦ Activa + wired + comprimida (%@). Presión de memoria: %@.
  Atividade de disco ¦ Disk activity ¦ Actividad de disco
  Atualizado a cada 30 s. Volumes APFS do mesmo contêiner compartilham espaço: não some capacidades. ¦ Updated every 30 s. APFS volumes in the same container share space: do not add up capacities. ¦ Actualizado cada 30 s. Los volúmenes APFS del mismo contenedor comparten espacio: no sumes capacidades.
  Atualizar ¦ Refresh ¦ Actualizar
  Atualizar agora (⌘R) ¦ Refresh now (⌘R) ¦ Actualizar ahora (⌘R)
  Atualização ¦ Refresh rate ¦ Actualización
  Até 12 processos · 120 amostras em memória. ¦ Up to 12 processes · 120 samples in memory. ¦ Hasta 12 procesos · 120 muestras en memoria.
  Banco de dados ¦ Database ¦ Base de datos
  Barra de menus ¦ Menu bar ¦ Barra de menús
  CPU (verde) e memória (azul) · até 10 min ¦ CPU (green) and memory (blue) · up to 10 min ¦ CPU (verde) y memoria (azul) · hasta 10 min
  CPU · atenção ¦ CPU · warning ¦ CPU · atención
  CPU · crítico ¦ CPU · critical ¦ CPU · crítico
  CPU ≥ 80%% de um núcleo há %@ s. ¦ CPU ≥ 80%% of one core for %@ s. ¦ CPU ≥ 80%% de un núcleo desde hace %@ s.
  CPU do CoreScope (um núcleo) ¦ CoreScope CPU (one core) ¦ CPU de CoreScope (un núcleo)
  Cancelar ¦ Cancel ¦ Cancelar
  Claro ¦ Light ¦ Claro
  Coleta ¦ Sampling ¦ Recolección
  Coleta demorando mais de 25 s; leituras anteriores estão antigas. ¦ Sampling is taking over 25 s; previous readings are stale. ¦ La recolección tarda más de 25 s; las lecturas anteriores están desactualizadas.
  Coleta local ao vivo ¦ Live local sampling ¦ Recolección local en vivo
  Coleta pausada ¦ Sampling paused ¦ Recolección en pausa
  Coleta pausada · dados anteriores ¦ Sampling paused · previous data ¦ Recolección en pausa · datos anteriores
  Coletando… ¦ Sampling… ¦ Recolectando…
  Com %@ descendente%@: CPU %@ · %@ ¦ With %@ descendant%@: CPU %@ · %@ ¦ Con %@ descendiente%@: CPU %@ · %@
  Compacto ¦ Compact ¦ Compacto
  Compressor físico ¦ Physical compressor ¦ Compresor físico
  Configuração inválida ¦ Invalid configuration ¦ Configuración no válida
  Confirmar antes de encerrar processos ¦ Confirm before terminating processes ¦ Confirmar antes de finalizar procesos
  Contadores físicos %@. ¦ Physical counters %@. ¦ Contadores físicos %@.
  Contadores por dispositivo do IOKit, não por volume APFS. I/O alto não mede saturação ou latência. ¦ Per-device IOKit counters, not per APFS volume. High I/O does not measure saturation or latency. ¦ Contadores por dispositivo de IOKit, no por volumen APFS. Un I/O alto no mide saturación ni latencia.
  Copiar PID ¦ Copy PID ¦ Copiar PID
  Copiar caminho ¦ Copy path ¦ Copiar ruta
  Copiar diretório ¦ Copy folder path ¦ Copiar carpeta
  Crítica ¦ Critical ¦ Crítica
  Crítico ¦ Critical ¦ Crítico
  DISCO ¦ DISK ¦ DISCO
  Dados antigos ¦ Stale data ¦ Datos antiguos
  Dados antigos · aguardando coleta ¦ Stale data · waiting for a sample ¦ Datos antiguos · esperando recolección
  Despertares do pacote atribuídos ao app ¦ Package wakeups attributed to the app ¦ Despertares del paquete atribuidos a la app
  Detalhado · com processos ¦ Detailed · with processes ¦ Detallado · con procesos
  Detalhado · processos ¦ Detailed · processes ¦ Detallado · procesos
  Detalhes ¦ Details ¦ Detalles
  Diretório ¦ Folder ¦ Carpeta
  Diretório: %@ ¦ Folder: %@ ¦ Carpeta: %@
  Disco ¦ Disk ¦ Disco
  Disco %@ ¦ Disk %@ ¦ Disco %@
  Dispositivos ¦ Devices ¦ Dispositivos
  Em repouso ¦ Asleep ¦ En reposo
  Em repouso · dados anteriores ¦ Asleep · previous data ¦ En reposo · datos anteriores
  Encerra a sessão e os %@ processos que ela iniciou ¦ Terminates the session and the %@ processes it started ¦ Finaliza la sesión y los %@ procesos que inició
  Encerra o agente e todos os processos que ele iniciou ¦ Terminates the agent and every process it started ¦ Finaliza el agente y todos los procesos que inició
  Encerrando %@ processos… ¦ Terminating %@ processes… ¦ Finalizando %@ procesos…
  Encerrando %@… ¦ Terminating %@… ¦ Finalizando %@…
  Encerrar ¦ Terminate ¦ Finalizar
  Encerrar %@ ¦ Terminate %@ ¦ Finalizar %@
  Encerrar %@ (PID %@)? ¦ Terminate %@ (PID %@)? ¦ ¿Finalizar %@ (PID %@)?
  Encerrar %@ (SIGTERM) ¦ Terminate %@ (SIGTERM) ¦ Finalizar %@ (SIGTERM)
  Encerrar %@ e %@ descendentes? ¦ Terminate %@ and %@ descendants? ¦ ¿Finalizar %@ y %@ descendientes?
  Encerrar %@ e descendentes… ¦ Terminate %@ and descendants… ¦ Finalizar %@ y descendientes…
  Encerrar %@ processos? ¦ Terminate %@ processes? ¦ ¿Finalizar %@ procesos?
  Encerrar todos ¦ Terminate all ¦ Finalizar todos
  Encerrar todos… ¦ Terminate all… ¦ Finalizar todos…
  Encerrar árvore ¦ Terminate tree ¦ Finalizar árbol
  Encerrar… ¦ Terminate… ¦ Finalizar…
  Energia em watts/joules e Energy Impact: indisponíveis por API pública integrada. Despertares de pacote não são todos os timers; custo total deve ser medido em uso real. Metas e medições estão no relatório do projeto. ¦ Power in watts/joules and Energy Impact: not available through an integrated public API. Package wakeups are not every timer; total cost must be measured in real use. Targets and measurements are in the project report. ¦ Energía en vatios/julios y Energy Impact: no disponibles mediante API pública integrada. Los despertares del paquete no son todos los temporizadores; el costo total debe medirse en uso real. Metas y mediciones en el informe del proyecto.
  Escrita ¦ Write ¦ Escritura
  Escuro ¦ Dark ¦ Oscuro
  Escutando em %@ ¦ Listening on %@ ¦ Escuchando en %@
  Escutando em todas as interfaces (acessível na rede) ¦ Listening on all interfaces (reachable on the network) ¦ Escuchando en todas las interfaces (accesible en la red)
  Espaço livre · atenção abaixo de ¦ Free space · warning below ¦ Espacio libre · atención por debajo de
  Espaço livre · crítico abaixo de ¦ Free space · critical below ¦ Espacio libre · crítico por debajo de
  Estado informado pelo sistema; não é uma temperatura em °C. ¦ State reported by the system; not a temperature in °C. ¦ Estado informado por el sistema; no es una temperatura en °C.
  Estado térmico do macOS ¦ macOS thermal state ¦ Estado térmico de macOS
  Executável ¦ Executable ¦ Ejecutable
  Exibição ¦ View ¦ Vista
  Expandir ¦ Expand ¦ Expandir
  Expandir tudo ¦ Expand all ¦ Expandir todo
  Fixado acima das janelas ¦ Pinned above windows ¦ Fijado sobre las ventanas
  Fixar acima das janelas ¦ Pin above windows ¦ Fijar sobre las ventanas
  Formato compacto ¦ Compact format ¦ Formato compacto
  Forçar ¦ Force ¦ Forzar
  Forçar (SIGKILL) ¦ Force (SIGKILL) ¦ Forzar (SIGKILL)
  Forçar encerramento ¦ Force quit ¦ Forzar cierre
  Forçar encerramento (SIGKILL) de %@ ¦ Force quit %@ (SIGKILL) ¦ Forzar cierre de %@ (SIGKILL)
  Forçar encerramento de %@ (PID %@)? ¦ Force quit %@ (PID %@)? ¦ ¿Forzar cierre de %@ (PID %@)?
  Forçar encerramento de %@ e %@ descendentes? ¦ Force quit %@ and %@ descendants? ¦ ¿Forzar cierre de %@ y %@ descendientes?
  Forçar encerramento de %@ processos? ¦ Force quit %@ processes? ¦ ¿Forzar cierre de %@ procesos?
  Forçar encerramento… ¦ Force quit… ¦ Forzar cierre…
  Geral ¦ General ¦ General
  Grande ¦ Large ¦ Grande
  Histerese de saída: 5 pontos de CPU e 2 pontos de espaço livre. Memória usa eventos reais do macOS; térmico usa os estados sério/crítico, com estabilização de 5 s. Não há ajuste que transforme ocupação de RAM em pressão. ¦ Exit hysteresis: 5 CPU points and 2 free-space points. Memory uses real macOS events; thermal uses the serious/critical states with 5 s stabilization. No setting turns RAM usage into pressure. ¦ Histéresis de salida: 5 puntos de CPU y 2 de espacio libre. La memoria usa eventos reales de macOS; lo térmico usa los estados serio/crítico con estabilización de 5 s. Ningún ajuste convierte el uso de RAM en presión.
  Histórico ¦ History ¦ Historial
  Idioma ¦ Language ¦ Idioma
  Indisponível ¦ Unavailable ¦ No disponible
  Iniciado pelo launchd (sem pai interativo) ¦ Started by launchd (no interactive parent) ¦ Iniciado por launchd (sin padre interactivo)
  Iniciado via %@ ¦ Started via %@ ¦ Iniciado desde %@
  Iniciado via %@ (PID %@) ¦ Started via %@ (PID %@) ¦ Iniciado desde %@ (PID %@)
  Iniciado via %@ · PID %@ ¦ Started via %@ · PID %@ ¦ Iniciado desde %@ · PID %@
  Iniciar ao entrar no macOS ¦ Open at login ¦ Abrir al iniciar sesión
  Inventário temporariamente indisponível. ¦ Inventory temporarily unavailable. ¦ Inventario temporalmente no disponible.
  Início %@ · ativo há %@ ¦ Started %@ · running for %@ ¦ Inicio %@ · activo desde hace %@
  Janela sustentada ¦ Sustained window ¦ Ventana sostenida
  Layout ¦ Layout ¦ Diseño
  Layout, tamanho, opacidade e opções ¦ Layout, size, opacity and options ¦ Diseño, tamaño, opacidad y opciones
  Leitura ¦ Read ¦ Lectura
  Leitura pública NVMe SMART a cada 30 s (temperatura composta do controlador), sem root e sem comandos de escrita. Adaptadores USB/SATA podem não expor SMART; ausência de leitura não significa temperatura normal. ¦ Public NVMe SMART reading every 30 s (controller composite temperature), without root or write commands. USB/SATA adapters may not expose SMART; a missing reading does not mean a normal temperature. ¦ Lectura pública NVMe SMART cada 30 s (temperatura compuesta del controlador), sin root ni comandos de escritura. Los adaptadores USB/SATA pueden no exponer SMART; la ausencia de lectura no significa temperatura normal.
  Lendo métricas do macOS… ¦ Reading macOS metrics… ¦ Leyendo métricas de macOS…
  Lendo processos… ¦ Reading processes… ¦ Leyendo procesos…
  Limites e estabilidade ¦ Thresholds and stability ¦ Límites y estabilidad
  Limpar processos acompanhados e ignorados ¦ Clear watched and ignored processes ¦ Limpiar procesos seguidos e ignorados
  Lista ¦ List ¦ Lista
  MAIS CPU ¦ TOP CPU ¦ MÁS CPU
  MEMÓRIA ¦ MEMORY ¦ MEMORIA
  Maior CPU ¦ Top CPU ¦ Mayor CPU
  Maior memória ¦ Top memory ¦ Mayor memoria
  Manter acima das janelas ¦ Keep above windows ¦ Mantener sobre las ventanas
  Memória ¦ Memory ¦ Memoria
  Memória do CoreScope · phys_footprint ¦ CoreScope memory · phys_footprint ¦ Memoria de CoreScope · phys_footprint
  Menos ¦ Less ¦ Menos
  Meus ¦ Mine ¦ Míos
  Moderado ¦ Fair ¦ Moderado
  Monitor para desenvolvedores ¦ Monitor for developers ¦ Monitor para desarrolladores
  Mostrar estado térmico ¦ Show thermal state ¦ Mostrar estado térmico
  Mostrar executável no Finder ¦ Show executable in Finder ¦ Mostrar ejecutable en Finder
  Mostrar no Finder ¦ Show in Finder ¦ Mostrar en Finder
  Mostrar no painel ¦ Show in panel ¦ Mostrar en el panel
  Mostrar ou ocultar detalhes ¦ Show or hide details ¦ Mostrar u ocultar detalles
  Mostrar ou ocultar o painel flutuante (⇧⌘P) ¦ Show or hide the floating panel (⇧⌘P) ¦ Mostrar u ocultar el panel flotante (⇧⌘P)
  Mostrar painel ¦ Show panel ¦ Mostrar panel
  Mostrar painel flutuante ¦ Show floating panel ¦ Mostrar panel flotante
  Mostrar rede ¦ Show network ¦ Mostrar red
  Mostrar ícone ¦ Show icon ¦ Mostrar icono
  Mostrar ícone no Dock ¦ Show icon in Dock ¦ Mostrar icono en el Dock
  Mover %@ para a direita ¦ Move %@ right ¦ Mover %@ a la derecha
  Mover %@ para a esquerda ¦ Move %@ left ¦ Mover %@ a la izquierda
  Médio ¦ Medium ¦ Mediano
  Nenhum ¦ None ¦ Ninguno
  Nenhum processo ¦ No process ¦ Ningún proceso
  Nenhum processo elegível para encerrar. ¦ No eligible process to terminate. ¦ Ningún proceso elegible para finalizar.
  Nenhum runtime de desenvolvimento rodando sem pai. ¦ No development runtime running without a parent. ¦ Ningún runtime de desarrollo ejecutándose sin padre.
  Nenhuma porta TCP aberta por processos seus. ¦ No TCP ports opened by your processes. ¦ Ningún puerto TCP abierto por tus procesos.
  Nenhuma sessão de Claude Code, Codex ou outro agente em execução (desktop ou terminal). ¦ No Claude Code, Codex or other agent session running (desktop or terminal). ¦ Ninguna sesión de Claude Code, Codex u otro agente en ejecución (escritorio o terminal).
  Nome, PID, porta, projeto ou agente ¦ Name, PID, port, project or agent ¦ Nombre, PID, puerto, proyecto o agente
  Nominal ¦ Nominal ¦ Nominal
  Normal ¦ Normal ¦ Normal
  Não há fonte pública em °C integrada para este hardware; APIs privadas de SMC/HID não são usadas. ¦ No public °C source is integrated for this hardware; private SMC/HID APIs are not used. ¦ No hay una fuente pública en °C integrada para este hardware; no se usan APIs privadas de SMC/HID.
  Não marcar como órfão ¦ Don't mark as orphan ¦ No marcar como huérfano
  Não marcar novamente ¦ Don't mark again ¦ No marcar de nuevo
  Não suportado ¦ Not supported ¦ No compatible
  O macOS recusou a alteração: %@ ¦ macOS refused the change: %@ ¦ macOS rechazó el cambio: %@
  O núcleo não retornou dados ¦ The core returned no data ¦ El núcleo no devolvió datos
  Ocultar painel ¦ Hide panel ¦ Ocultar panel
  Ocultar painel flutuante ¦ Hide floating panel ¦ Ocultar panel flotante
  Onde ¦ Where ¦ Dónde
  Opacidade do fundo ¦ Background opacity ¦ Opacidad del fondo
  Origem ¦ Origin ¦ Origen
  PID %@ · %@ · pai %@ ¦ PID %@ · %@ · parent %@ ¦ PID %@ · %@ · padre %@
  Padrão ¦ Standard ¦ Estándar
  Pai observado: %@ ¦ Observed parent: %@ ¦ Padre observado: %@
  Painel flutuante ¦ Floating panel ¦ Panel flotante
  Parar de acompanhar ¦ Stop tracking ¦ Dejar de seguir
  Pausado ¦ Paused ¦ En pausa
  Pausar ¦ Pause ¦ Pausar
  Pausar coleta ¦ Pause sampling ¦ Pausar recolección
  Pequeno ¦ Small ¦ Pequeño
  Portas ¦ Ports ¦ Puertos
  Portas em escuta ¦ Listening ports ¦ Puertos en escucha
  Posição travada ¦ Position locked ¦ Posición bloqueada
  Possíveis órfãos ¦ Possible orphans ¦ Posibles huérfanos
  Possível órfão ¦ Possible orphan ¦ Posible huérfano
  Pressão de memória · último evento ¦ Memory pressure · last event ¦ Presión de memoria · último evento
  Privacidade e custo do monitor ¦ Privacy and monitor cost ¦ Privacidad y costo del monitor
  Processo ¦ Process ¦ Proceso
  Processos ¦ Processes ¦ Procesos
  Processos de desenvolvimento sem pai (adotados pelo launchd) ou cujo pai encerrou enquanto o CoreScope observava. Confirme a finalidade antes de encerrar. ¦ Development processes without a parent (adopted by launchd) or whose parent exited while CoreScope was watching. Confirm their purpose before terminating. ¦ Procesos de desarrollo sin padre (adoptados por launchd) o cuyo padre terminó mientras CoreScope observaba. Confirma su finalidad antes de finalizarlos.
  Processos protegidos ou de outro usuário serão ignorados. ¦ Protected processes or those of other users will be skipped. ¦ Se omitirán los procesos protegidos o de otros usuarios.
  Projeto ¦ Project ¦ Proyecto
  Projeto · origem ¦ Project · origin ¦ Proyecto · origen
  REDE ¦ NETWORK ¦ RED
  Recolher ¦ Collapse ¦ Contraer
  Recolher tudo ¦ Collapse all ¦ Contraer todo
  Recursos ¦ Resources ¦ Recursos
  Rede ¦ Network ¦ Red
  Registro IOKit %@ ¦ IOKit registry %@ ¦ Registro IOKit %@
  Residente ¦ Resident ¦ Residente
  Retomar ¦ Resume ¦ Reanudar
  Retomar coleta ¦ Resume sampling ¦ Reanudar recolección
  SERVIDORES ¦ SERVERS ¦ SERVIDORES
  SIGKILL encerra imediatamente: trabalho não salvo é perdido. ¦ SIGKILL ends immediately: unsaved work is lost. ¦ SIGKILL finaliza de inmediato: el trabajo no guardado se pierde.
  SIGTERM pede encerramento; builds, agentes e servidores serão interrompidos. ¦ SIGTERM asks to quit; builds, agents and servers will be interrupted. ¦ SIGTERM pide finalizar; builds, agentes y servidores se interrumpirán.
  Sair ¦ Quit ¦ Salir
  Selecionar o processo de origem ¦ Select the origin process ¦ Seleccionar el proceso de origen
  Selecione processos para agir · ⌫ encerra · ←/→ recolhe e expande ¦ Select processes to act · ⌫ terminates · ←/→ collapse and expand ¦ Selecciona procesos para actuar · ⌫ finaliza · ←/→ contrae y expande
  Selecione um processo para ver origem, portas, recursos e ações. ¦ Select a process to see its origin, ports, resources and actions. ¦ Selecciona un proceso para ver origen, puertos, recursos y acciones.
  Sem alerta ¦ No alert ¦ Sin alerta
  Sem app de origem ¦ No origin app ¦ Sin app de origen
  Sem confirmação, o botão ✕ envia SIGTERM no primeiro clique. Encerrar árvore e forçar (SIGKILL) sempre pedem confirmação. ¦ Without confirmation, the ✕ button sends SIGTERM on the first click. Terminating a tree and forcing (SIGKILL) always ask first. ¦ Sin confirmación, el botón ✕ envía SIGTERM con el primer clic. Finalizar un árbol y forzar (SIGKILL) siempre piden confirmación.
  Sem permissão ¦ No permission ¦ Sin permiso
  Sem rede ou telemetria. Sem argumentos, ambiente, logs de processos ou banco de dados. Preferências e identidades acompanhadas/ignoradas ficam no UserDefaults. Histórico somente em RAM, até 120 amostras / 10 minutos. ¦ No network or telemetry. No arguments, environment, process logs or database. Preferences and watched/ignored identities live in UserDefaults. History only in RAM, up to 120 samples / 10 minutes. ¦ Sin red ni telemetría. Sin argumentos, entorno, registros de procesos ni base de datos. Preferencias e identidades seguidas/ignoradas quedan en UserDefaults. Historial solo en RAM, hasta 120 muestras / 10 minutos.
  Sensor no menu e painel ¦ Sensor in menu and panel ¦ Sensor en menú y panel
  Sensores ¦ Sensors ¦ Sensores
  Servidor ¦ Server ¦ Servidor
  Servidores ¦ Servers ¦ Servidores
  Servidores em escuta ¦ Listening servers ¦ Servidores en escucha
  Sessões de agentes ¦ Agent sessions ¦ Sesiones de agentes
  Sistema ¦ System ¦ Sistema
  Sobre o CoreScope ¦ About CoreScope ¦ Acerca de CoreScope
  Soma do processo e de todos os descendentes ¦ Sum of the process and all descendants ¦ Suma del proceso y todos sus descendientes
  Somente local ¦ Local only ¦ Solo local
  Somente local (loopback) ¦ Local only (loopback) ¦ Solo local (loopback)
  Swap ocupado ¦ Swap used ¦ Swap ocupado
  Sério ¦ Serious ¦ Serio
  Tamanho ¦ Size ¦ Tamaño
  Tema ¦ Theme ¦ Tema
  Temperatura NVMe ¦ NVMe temperature ¦ Temperatura NVMe
  Temperatura de CPU / SoC: não suportado ¦ CPU / SoC temperature: not supported ¦ Temperatura de CPU / SoC: no compatible
  Temporariamente indisponível ¦ Temporarily unavailable ¦ Temporalmente no disponible
  Todas essas opções também ficam no próprio painel: botão ⋯ ou clique com o botão direito. ¦ All of these options are also on the panel itself: the ⋯ button or a right click. ¦ Todas estas opciones también están en el propio panel: botón ⋯ o clic derecho.
  Todos ¦ All ¦ Todos
  Travar posição ¦ Lock position ¦ Bloquear posición
  Trazer painel para a tela principal ¦ Bring panel to the main display ¦ Traer el panel a la pantalla principal
  Trazer para a tela principal ¦ Bring to the main display ¦ Traer a la pantalla principal
  Térmico ¦ Thermal ¦ Térmico
  Um único coletor atende todas as superfícies. Em economia de energia ou sem detalhes visíveis, o intervalo mínimo é 10 s. Pausa durante repouso; deltas são descartados no retorno. ¦ A single collector serves every surface. In Low Power Mode or with no details visible, the minimum interval is 10 s. Pauses during sleep; deltas are discarded on wake. ¦ Un único recolector sirve a todas las superficies. En ahorro de energía o sin detalles visibles, el intervalo mínimo es 10 s. Se pausa en reposo; los deltas se descartan al volver.
  Ver processos ¦ Show processes ¦ Ver procesos
  Ver todos ¦ See all ¦ Ver todos
  Visão geral ¦ Overview ¦ Resumen
  Volumes montados ¦ Mounted volumes ¦ Volúmenes montados
  de %@ · swap %@ ¦ of %@ · swap %@ ¦ de %@ · swap %@
  entrada ¦ in ¦ entrada
  escrita ¦ write ¦ escritura
  falha interna ¦ internal failure ¦ fallo interno
  leitura ¦ read ¦ lectura
  local ¦ local ¦ local
  rede ¦ network ¦ red
  saída ¦ out ¦ salida
  via %@ ¦ via %@ ¦ desde %@
  Árvore ¦ Tree ¦ Árbol
  Árvore (%@) ¦ Tree (%@) ¦ Árbol (%@)
  ÓRFÃOS ¦ ORPHANS ¦ HUÉRFANOS
  Órfãos ¦ Orphans ¦ Huérfanos
  Última leitura: %@ ¦ Last reading: %@ ¦ Última lectura: %@
  Última passagem do coletor ¦ Last collector pass ¦ Última pasada del recolector
  órfão ¦ orphan ¦ huérfano
  ↓ %@  ↑ %@ · soma dos dispositivos físicos ¦ ↓ %@  ↑ %@ · sum of physical devices ¦ ↓ %@  ↑ %@ · suma de los dispositivos físicos
  indisponível ¦ unavailable ¦ no disponible
  não suportados ¦ not supported ¦ no compatibles
  temporariamente indisponíveis ¦ temporarily unavailable ¦ temporalmente no disponibles
  CPU em aquecimento ¦ CPU warming up ¦ CPU calentando
  CPU elevada de forma sustentada ¦ Sustained high CPU ¦ CPU alta de forma sostenida
  CPU sem alerta sustentado ¦ No sustained CPU alert ¦ CPU sin alerta sostenida
  Total normalizado em 0–100%, com janela sustentada configurável; saída 5 pontos abaixo do limite. Consumo alto não comprova a causa de lentidão. ¦ Total normalized to 0–100%, with a configurable sustained window; exits 5 points below the threshold. High usage does not prove the cause of slowness. ¦ Total normalizado en 0–100%, con ventana sostenida configurable; sale 5 puntos por debajo del límite. Un consumo alto no prueba la causa de la lentitud.
  Evento de pressão crítica de memória ¦ Critical memory pressure event ¦ Evento de presión crítica de memoria
  Evento de pressão de memória ¦ Memory pressure event ¦ Evento de presión de memoria
  Último evento de memória: normal ¦ Last memory event: normal ¦ Último evento de memoria: normal
  Pressão de memória ainda não informada ¦ Memory pressure not reported yet ¦ Presión de memoria aún no informada
  Fonte: eventos Dispatch do macOS. RAM ativa, wired e compressor são contagens distintas; não equivalem à pressão. Swap ocupado, isoladamente, não indica problema atual. ¦ Source: macOS Dispatch events. Active, wired and compressed RAM are separate counts; they are not pressure. Swap in use, by itself, does not indicate a current problem. ¦ Fuente: eventos Dispatch de macOS. La RAM activa, wired y comprimida son conteos distintos; no equivalen a presión. El swap ocupado, por sí solo, no indica un problema actual.
  Condição térmica nominal ¦ Nominal thermal condition ¦ Condición térmica nominal
  Condição térmica moderada ¦ Fair thermal condition ¦ Condición térmica moderada
  Condição térmica séria ¦ Serious thermal condition ¦ Condición térmica seria
  Condição térmica crítica ¦ Critical thermal condition ¦ Condición térmica crítica
  Condição térmica indisponível ¦ Thermal condition unavailable ¦ Condición térmica no disponible
  Estado informado pelo macOS; não é temperatura em °C. Em estado sério/crítico, reduza tarefas concorrentes e verifique ventilação. ¦ State reported by macOS; not a temperature in °C. In serious/critical state, reduce concurrent tasks and check ventilation. ¦ Estado informado por macOS; no es temperatura en °C. En estado serio/crítico, reduce tareas concurrentes y revisa la ventilación.
  Pouco espaço em um volume ¦ Low space on a volume ¦ Poco espacio en un volumen
  Armazenamento: confira capacidade e atividade ¦ Storage: check capacity and activity ¦ Almacenamiento: revisa capacidad y actividad
  Volumes APFS podem compartilhar espaço: não some suas capacidades. Taxa alta de I/O não mede saturação ou latência; esta versão não diagnostica pressão de I/O. ¦ APFS volumes can share space: do not add up their capacities. A high I/O rate does not measure saturation or latency; this version does not diagnose I/O pressure. ¦ Los volúmenes APFS pueden compartir espacio: no sumes sus capacidades. Una tasa alta de I/O no mide saturación ni latencia; esta versión no diagnostica presión de I/O.
  Identidade inválida ou processo do sistema ¦ Invalid identity or system process ¦ Identidad no válida o proceso del sistema
  Pertence a outro usuário ¦ Belongs to another user ¦ Pertenece a otro usuario
  Processo protegido ou ancestral do CoreScope ¦ Protected process or CoreScope ancestor ¦ Proceso protegido o ancestro de CoreScope
  Serviço essencial protegido ¦ Protected essential service ¦ Servicio esencial protegido
  Executável indisponível; ação bloqueada ¦ Executable unavailable; action blocked ¦ Ejecutable no disponible; acción bloqueada
  Identidade inválida ¦ Invalid identity ¦ Identidad no válida
  Processo encerrou ou está sem permissão ¦ Process exited or is not accessible ¦ El proceso terminó o no hay permiso
  Identidade mudou; PID reutilizado ou executável alterado ¦ Identity changed; PID reused or executable changed ¦ La identidad cambió; PID reutilizado o ejecutable modificado
  Processo não está mais disponível ¦ Process is no longer available ¦ El proceso ya no está disponible
  Identidade mudou durante a confirmação ¦ Identity changed during confirmation ¦ La identidad cambió durante la confirmación
  Executável ausente ¦ Missing executable ¦ Ejecutable ausente
  Executável inválido ¦ Invalid executable ¦ Ejecutable no válido
  Configuração ausente ¦ Missing configuration ¦ Configuración ausente
  Coletor indisponível ¦ Collector unavailable ¦ Recolector no disponible
  Falha interna contida; reinicie a coleta ¦ Internal failure contained; restart sampling ¦ Fallo interno contenido; reinicia la recolección
  O processo pai encerrou e este continuou rodando, adotado pelo launchd. ¦ The parent process exited and this one kept running, adopted by launchd. ¦ El proceso padre terminó y este siguió ejecutándose, adoptado por launchd.
  Sem processo pai: adotado pelo launchd. Runtimes de desenvolvimento costumam ter terminal, editor ou agente como pai; pode ser um serviço iniciado de propósito. ¦ No parent process: adopted by launchd. Development runtimes usually have a terminal, editor or agent as parent; it may be a service started on purpose. ¦ Sin proceso padre: adoptado por launchd. Los runtimes de desarrollo suelen tener un terminal, editor o agente como padre; puede ser un servicio iniciado a propósito.
  Mostrar ou ocultar painel flutuante ¦ Show or hide floating panel ¦ Mostrar u ocultar panel flotante
  Pausar ou retomar coleta ¦ Pause or resume sampling ¦ Pausar o reanudar recolección
  Ícone no Dock ¦ Dock icon ¦ Icono en el Dock
  Sempre ¦ Always ¦ Siempre
  Só com a janela aberta ¦ Only while the window is open ¦ Solo con la ventana abierta
  Nunca (só barra de menus) ¦ Never (menu bar only) ¦ Nunca (solo barra de menús)
  Agentes ¦ Agents ¦ Agentes
  Semanal ¦ Weekly ¦ Semanal
  5 horas ¦ 5 hours ¦ 5 horas
  %@ dias ¦ %@ days ¦ %@ días
  %@ h ¦ %@ h ¦ %@ h
  reinicia em %@ ¦ resets in %@ ¦ se reinicia en %@
  Limites de uso ¦ Usage limits ¦ Límites de uso
  Sem eventos de limite nos logs recentes do Codex. ¦ No limit events in recent Codex logs. ¦ Sin eventos de límite en los registros recientes de Codex.
  Plano %@ ¦ Plan %@ ¦ Plan %@
  créditos %@ ¦ credits %@ ¦ créditos %@
  lido %@ ¦ read %@ ¦ leído %@
  Sessões ativas ¦ Active sessions ¦ Sesiones activas
  %@ processos · CPU %@ · %@ ¦ %@ processes · CPU %@ · %@ ¦ %@ procesos · CPU %@ · %@
  Trabalhando ¦ Working ¦ Trabajando
  Ociosa ¦ Idle ¦ Inactiva
  ativo há %@ ¦ running for %@ ¦ activo desde hace %@
  Encerrar sessão… ¦ Terminate session… ¦ Finalizar sesión…
  %@ processos iniciados pela sessão ¦ %@ processes started by the session ¦ %@ procesos iniciados por la sesión
  Ver agentes ¦ See agents ¦ Ver agentes
  Limites na visão geral ¦ Limits in the overview ¦ Límites en el resumen
  Abrir no Claude ¦ Open in Claude ¦ Abrir en Claude
  Mostrar no %@ ¦ Show in %@ ¦ Mostrar en %@
  Abre esta sessão no Claude Desktop ¦ Opens this session in Claude Desktop ¦ Abre esta sesión en Claude Desktop
  Traz %@, onde a sessão está rodando, para a frente ¦ Brings %@, where the session runs, to the front ¦ Trae al frente %@, donde se ejecuta la sesión
  Mostrar limites dos agentes ¦ Show agent limits ¦ Mostrar límites de los agentes
  Limites na barra de menus ¦ Limits in the menu bar ¦ Límites en la barra de menús
  Limites no painel flutuante ¦ Limits in the floating panel ¦ Límites en el panel flotante
  O limite do Codex vem dos eventos rate_limits que o próprio Codex grava em ~/.codex/sessions (somente leitura local). Sessões do Claude vêm de ~/.claude/sessions. ¦ The Codex limit comes from the rate_limits events Codex itself writes to ~/.codex/sessions (local read only). Claude sessions come from ~/.claude/sessions. ¦ El límite de Codex viene de los eventos rate_limits que el propio Codex escribe en ~/.codex/sessions (solo lectura local). Las sesiones de Claude vienen de ~/.claude/sessions.
  Ler limite do Claude pelo status line ¦ Read the Claude limit from the status line ¦ Leer el límite de Claude desde la línea de estado
  Desligado por padrão. Ao ligar, o CoreScope instala um comando de status line em ~/.claude/settings.json (com backup; se você já tiver um status line, nada é trocado sem sua confirmação). A cada resposta, o próprio Claude Code passa o uso do plano a esse comando, que grava só rate_limits em ~/Library/Application Support/CoreScope. Sem Keychain, sem credenciais, sem rede. Desligar restaura o statusLine anterior. Só planos Pro e Max informam o limite. ¦ Off by default. Turning it on installs a status line command in ~/.claude/settings.json (backed up first; if you already have a status line, nothing is replaced without your confirmation). After each reply, Claude Code itself hands your plan usage to that command, which saves only rate_limits to ~/Library/Application Support/CoreScope. No Keychain, no credentials, no network. Turning it off restores the previous statusLine. Only Pro and Max plans report the limit. ¦ Desactivado por defecto. Al activarlo, CoreScope instala un comando de línea de estado en ~/.claude/settings.json (con copia de seguridad; si ya tienes una línea de estado, no se reemplaza nada sin tu confirmación). Tras cada respuesta, el propio Claude Code pasa el uso del plan a ese comando, que guarda solo rate_limits en ~/Library/Application Support/CoreScope. Sin Llavero, sin credenciales, sin red. Al desactivarlo se restaura el statusLine anterior. Solo los planes Pro y Max informan el límite.
  Status line do CoreScope instalado. ¦ CoreScope status line installed. ¦ Línea de estado de CoreScope instalada.
  Encadeado com o seu status line; a saída dele continua a mesma. ¦ Chained with your status line; its output stays the same. ¦ Encadenado con tu línea de estado; su salida sigue igual.
  Você já tem um status line, por isso nada foi alterado: ¦ You already have a status line, so nothing was changed: ¦ Ya tienes una línea de estado, así que no se cambió nada:
  Encadear com o status line atual ¦ Chain with the current status line ¦ Encadenar con la línea de estado actual
  Coloca o comando do CoreScope antes do seu; a saída do seu status line não muda. ¦ Puts CoreScope's command in front of yours; your status line output does not change. ¦ Pone el comando de CoreScope delante del tuyo; la salida de tu línea de estado no cambia.
  Ou edite à mão: comece o comando com ¦ Or edit it by hand: start the command with ¦ O edítalo a mano: empieza el comando con
  ~/.claude/settings.json não é um JSON válido; nada foi alterado. ¦ ~/.claude/settings.json is not valid JSON; nothing was changed. ¦ ~/.claude/settings.json no es un JSON válido; no se cambió nada.
  ~/.claude/settings.json não é um objeto JSON; nada foi alterado. ¦ ~/.claude/settings.json is not a JSON object; nothing was changed. ¦ ~/.claude/settings.json no es un objeto JSON; no se cambió nada.
  O statusLine mudou desde que o CoreScope o instalou; ele foi mantido como está. ¦ The statusLine changed since CoreScope installed it, so it was left as is. ¦ El statusLine cambió desde que CoreScope lo instaló, así que se dejó como está.
  Não foi possível gravar: %@ ¦ Could not write: %@ ¦ No se pudo escribir: %@
  atualizado %@ ¦ updated %@ ¦ actualizado %@
  renova a cada resposta do Claude Code ¦ refreshes after each Claude Code reply ¦ se renueva tras cada respuesta de Claude Code
  O Claude Code não grava o limite em disco. Ative “Ler limite do Claude pelo status line” em Ajustes › Agentes (local, sem credenciais nem rede). ¦ Claude Code does not store its limit on disk. Turn on “Read the Claude limit from the status line” in Settings › Agents (local, no credentials, no network). ¦ Claude Code no guarda el límite en disco. Activa “Leer el límite de Claude desde la línea de estado” en Ajustes › Agentes (local, sin credenciales ni red).
  Você já tem um status line no Claude Code. Encadeie-o em Ajustes › Agentes para ler o limite. ¦ You already have a Claude Code status line. Chain it in Settings › Agents to read the limit. ¦ Ya tienes una línea de estado en Claude Code. Encadénala en Ajustes › Agentes para leer el límite.
  Aguardando a próxima resposta do Claude Code (só planos Pro e Max informam o limite). ¦ Waiting for the next Claude Code reply (only Pro and Max plans report the limit). ¦ Esperando la próxima respuesta de Claude Code (solo los planes Pro y Max informan el límite).
  %@ não está em execução. ¦ %@ is not running. ¦ %@ no se está ejecutando.
  %@ parado. ¦ %@ stopped. ¦ %@ detenido.
  %@ parados ¦ %@ stopped ¦ %@ detenidos
  %@ reiniciado. ¦ %@ restarted. ¦ %@ reiniciado.
  + %@ contêineres ¦ + %@ containers ¦ + %@ contenedores
  Ação de contêiner inválida ¦ Invalid container action ¦ Acción de contenedor no válida
  CPU %@ · %@ ¦ CPU %@ · %@ ¦ CPU %@ · %@
  Com falha ¦ Unhealthy ¦ Con fallos
  Contêiner ¦ Container ¦ Contenedor
  Contêiner não encontrado ¦ Container not found ¦ Contenedor no encontrado
  Contêineres ¦ Containers ¦ Contenedores
  Criado ¦ Created ¦ Creado
  Falha ao ler contêineres: %@ ¦ Could not read containers: %@ ¦ No se pudieron leer los contenedores: %@
  Identificador de contêiner inválido ¦ Invalid container ID ¦ Identificador de contenedor no válido
  Imagem ¦ Image ¦ Imagen
  Iniciando ¦ Starting ¦ Iniciando
  Lendo contêineres… ¦ Reading containers… ¦ Leyendo contenedores…
  Lido do socket local do Docker Engine (OrbStack, Docker Desktop ou Colima) a cada 5 s enquanto visível. CPU em % de um núcleo; memória sem cache de arquivos, como em docker stats. ¦ Read from the local Docker Engine socket (OrbStack, Docker Desktop or Colima) every 5 s while visible. CPU in % of one core; memory excludes file cache, as in docker stats. ¦ Leído del socket local de Docker Engine (OrbStack, Docker Desktop o Colima) cada 5 s mientras está visible. CPU en % de un núcleo; memoria sin caché de archivos, como en docker stats.
  Limite %@ ¦ Limit %@ ¦ Límite %@
  Leitor de contêineres indisponível ¦ Container reader unavailable ¦ Lector de contenedores no disponible
  Nenhum contêiner em %@. ¦ No containers in %@. ¦ No hay contenedores en %@.
  Nenhum motor de contêineres encontrado (OrbStack, Docker Desktop ou Colima). ¦ No container engine found (OrbStack, Docker Desktop or Colima). ¦ No se encontró ningún motor de contenedores (OrbStack, Docker Desktop o Colima).
  O motor de contêineres não respondeu ¦ The container engine did not respond ¦ El motor de contenedores no respondió
  O motor recusou a ação ¦ The engine refused the action ¦ El motor rechazó la acción
  Parado ¦ Stopped ¦ Detenido
  Parando %@… ¦ Stopping %@… ¦ Deteniendo %@…
  Parar ¦ Stop ¦ Detener
  Parar o contêiner %@ ¦ Stop container %@ ¦ Detener el contenedor %@
  Porta %@ do contêiner ¦ Container port %@ ¦ Puerto %@ del contenedor
  Porta publicada pelo contêiner %@ (%@); o processo %@ apenas a encaminha. ¦ Port published by container %@ (%@); the %@ process only forwards it. ¦ Puerto publicado por el contenedor %@ (%@); el proceso %@ solo lo reenvía.
  Reiniciando ¦ Restarting ¦ Reiniciando
  Reiniciando %@… ¦ Restarting %@… ¦ Reiniciando %@…
  Reiniciar ¦ Restart ¦ Reiniciar
  Reiniciar o contêiner %@ ¦ Restart container %@ ¦ Reiniciar el contenedor %@
  Rodando ¦ Running ¦ En ejecución
  Sem permissão para o socket de %@. ¦ No permission for the %@ socket. ¦ Sin permiso para el socket de %@.
  Serviço %@ ¦ Service %@ ¦ Servicio %@
  Saudável ¦ Healthy ¦ Saludable
  contêiner %@ ¦ container %@ ¦ contenedor %@
  Histórico de %@ ¦ %@ history ¦ Historial de %@
  último %@, pico %@ ¦ latest %@, peak %@ ¦ último %@, pico %@
  Uso ¦ Usage ¦ Uso
  Porta %@ ¦ Port %@ ¦ Puerto %@
  %@ não pode ser encerrado ¦ %@ cannot be terminated ¦ %@ no se puede finalizar
  Confirmar: encerrar %@ ¦ Confirm: terminate %@ ¦ Confirmar: finalizar %@
  Confirmar: forçar %@ ¦ Confirm: force quit %@ ¦ Confirmar: forzar %@
  Encerrar sessão %@ ¦ Terminate session %@ ¦ Finalizar sesión %@
  Forçar encerramento de %@ ¦ Force quit %@ ¦ Forzar la finalización de %@
  Abrir localhost:%@ no navegador ¦ Open localhost:%@ in the browser ¦ Abrir localhost:%@ en el navegador
  Dispensar ¦ Dismiss ¦ Descartar
  Ativado ¦ On ¦ Activado
  Desativado ¦ Off ¦ Desactivado
  Opções do painel ¦ Panel options ¦ Opciones del panel
  Limpar busca ¦ Clear search ¦ Borrar búsqueda
  Mostrar detalhes ¦ Show details ¦ Mostrar detalles
  Ocultar detalhes ¦ Hide details ¦ Ocultar detalles
  Expandir %@ ¦ Expand %@ ¦ Expandir %@
  Recolher %@ ¦ Collapse %@ ¦ Contraer %@
  Acompanhado ¦ Watched ¦ Seguido
  Total com descendentes: %@ ¦ Total with descendants: %@ ¦ Total con descendientes: %@
  Expandido ¦ Expanded ¦ Expandido
  Recolhido ¦ Collapsed ¦ Contraído
  """
