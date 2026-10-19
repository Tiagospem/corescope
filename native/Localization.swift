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
func L(_ key: String, _ args: String...) -> String { L(key, args) }
func L(_ key: String, _ args: [String]) -> String {
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
  Sem rede ou telemetria. Sem argumentos, ambiente ou logs de processos. Preferências e identidades acompanhadas/ignoradas ficam no UserDefaults. Gráficos ao vivo em RAM (120 amostras / 10 minutos); o histórico persistente é opcional e local. ¦ No network or telemetry. No arguments, environment or process logs. Preferences and watched/ignored identities live in UserDefaults. Live charts in RAM (120 samples / 10 minutes); persistent history is opt-in and local. ¦ Sin red ni telemetría. Sin argumentos, entorno ni registros de procesos. Preferencias e identidades seguidas/ignoradas quedan en UserDefaults. Gráficos en vivo en RAM (120 muestras / 10 minutos); el historial persistente es opcional y local.
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
  Gravação desligada: mostrando o histórico já salvo. Ative em Ajustes › Histórico. ¦ Recording is off: showing history already saved. Turn it on in Settings › History. ¦ Grabación desactivada: se muestra el historial ya guardado. Actívala en Ajustes › Historial.
  Período ¦ Range ¦ Periodo
  Período anterior ¦ Previous period ¦ Periodo anterior
  Próximo período ¦ Next period ¦ Periodo siguiente
  Até ¦ Until ¦ Hasta
  Agora ¦ Now ¦ Ahora
  Gravando · %@ dias · %@ ¦ Recording · %@ days · %@ ¦ Grabando · %@ días · %@
  %@ minutos salvos desde %@. Resumos de 1 minuto, gravados uma vez por minuto. ¦ %@ minutes saved since %@. One-minute summaries, written once per minute. ¦ %@ minutos guardados desde %@. Resúmenes de 1 minuto, escritos una vez por minuto.
  média ¦ mean ¦ media
  pico ¦ peak ¦ pico
  usada ¦ used ¦ usada
  swap ¦ swap ¦ swap
  Sem dados ¦ No data ¦ Sin datos
  média %@ ¦ mean %@ ¦ media %@
  máx. %@ ¦ max %@ ¦ máx. %@
  Histórico persistente ¦ Persistent history ¦ Historial persistente
  Responda “o que deixou o Mac lento ontem às 15h?”: com o histórico ligado, o CoreScope guarda a cada minuto CPU, memória, swap, disco, rede, estado térmico e os 10 processos que mais usaram CPU e memória. ¦ Answer “what made my Mac slow yesterday at 3 pm?”: with history on, CoreScope saves CPU, memory, swap, disk, network, thermal state and the 10 processes using the most CPU and memory every minute. ¦ Responde “¿qué hizo lento el Mac ayer a las 15 h?”: con el historial activado, CoreScope guarda cada minuto CPU, memoria, swap, disco, red, estado térmico y los 10 procesos que más CPU y memoria usaron.
  Fica só neste Mac, em ~/Library/Application Support/CoreScope. Nunca grava argumentos ou variáveis de ambiente. Desligado por padrão; apague tudo quando quiser. ¦ It stays on this Mac, in ~/Library/Application Support/CoreScope. Arguments and environment variables are never saved. Off by default; delete it all whenever you want. ¦ Se queda en este Mac, en ~/Library/Application Support/CoreScope. Nunca guarda argumentos ni variables de entorno. Desactivado por defecto; bórralo todo cuando quieras.
  Ativar histórico (7 dias) ¦ Turn on history (7 days) ¦ Activar historial (7 días)
  Abrir ajustes ¦ Open Settings ¦ Abrir ajustes
  Selecionado: %@ – %@ ¦ Selected: %@ – %@ ¦ Seleccionado: %@ – %@
  %@ amostras ¦ %@ samples ¦ %@ muestras
  Sem registro neste intervalo ¦ Nothing recorded in this interval ¦ Sin registros en este intervalo
  Clique em um gráfico para ver o que dominou naquele momento ¦ Click a chart to see what dominated at that moment ¦ Haz clic en un gráfico para ver qué dominó en ese momento
  Nenhum momento selecionado ¦ No moment selected ¦ Ningún momento seleccionado
  Selecionar horário de %@ ¦ Select time for %@ ¦ Seleccionar hora de %@
  Use as setas esquerda e direita ou ações do VoiceOver para mudar o horário ¦ Use the left and right arrow keys or VoiceOver actions to change the time ¦ Usa las flechas izquierda y derecha o las acciones de VoiceOver para cambiar la hora
  Térmico e pressão de memória ¦ Thermal and memory pressure ¦ Térmico y presión de memoria
  Eventos de pressão ¦ Pressure events ¦ Eventos de presión
  Pressão % ¦ Pressure % ¦ Presión %
  Térmico: pior estado do macOS no intervalo (não é °C). Eventos: pior aviso Dispatch de pressão. Pressão %: 100 − memória disponível segundo o kernel (kern.memorystatus_level), máximo do intervalo. ¦ Thermal: worst macOS state in the interval (not °C). Events: worst Dispatch pressure warning. Pressure %: 100 − memory available according to the kernel (kern.memorystatus_level), interval maximum. ¦ Térmico: peor estado de macOS en el intervalo (no son °C). Eventos: peor aviso Dispatch de presión. Presión %: 100 − memoria disponible según el kernel (kern.memorystatus_level), máximo del intervalo.
  O que dominou ¦ What dominated ¦ Qué dominó
  %@ minutos registrados ¦ %@ minutes recorded ¦ %@ minutos registrados
  %.1f%% ¦ %.1f%% ¦ %.1f%%
  pico %@ ¦ peak %@ ¦ pico %@
  %@ min no top ¦ %@ min in top ¦ %@ min en el top
  CPU: média em % de um núcleo sobre os minutos do intervalo; minutos fora do top 10 contam como zero. Memória: maior phys_footprint registrado. Agrupado por executável, diretório e origem. ¦ CPU: mean as % of one core over the interval's minutes; minutes outside the top 10 count as zero. Memory: highest phys_footprint recorded. Grouped by executable, folder and origin. ¦ CPU: media en % de un núcleo sobre los minutos del intervalo; los minutos fuera del top 10 cuentan como cero. Memoria: mayor phys_footprint registrado. Agrupado por ejecutable, carpeta y origen.
  Nada registrado neste intervalo (Mac em repouso, app fechado ou histórico desligado). ¦ Nothing recorded in this interval (Mac asleep, app closed or history off). ¦ Nada registrado en este intervalo (Mac en reposo, app cerrada o historial desactivado).
  Núcleos ¦ Cores ¦ Núcleos
  Desempenho (P) ¦ Performance (P) ¦ Rendimiento (P)
  Eficiência (E) ¦ Efficiency (E) ¦ Eficiencia (E)
  CPU por núcleo ¦ CPU per core ¦ CPU por núcleo
  Contadores por núcleo temporariamente indisponíveis. ¦ Per-core counters temporarily unavailable. ¦ Contadores por núcleo temporalmente no disponibles.
  %@ · %@ ¦ %@ · %@ ¦ %@ · %@
  host_processor_info indisponível ¦ host_processor_info unavailable ¦ host_processor_info no disponible
  sysctl · um único nível de desempenho ¦ sysctl · a single performance level ¦ sysctl · un único nivel de rendimiento
  Tipo por núcleo indisponível (mapa do IODeviceTree incompleto) ¦ Per-core type unavailable (incomplete IODeviceTree map) ¦ Tipo por núcleo no disponible (mapa de IODeviceTree incompleto)
  IODeviceTree · cluster-type, conferido com sysctl hw.perflevel0/1 ¦ IODeviceTree · cluster-type, checked against sysctl hw.perflevel0/1 ¦ IODeviceTree · cluster-type, verificado con sysctl hw.perflevel0/1
  Ticks por CPU lógica via host_processor_info; o tipo de cada núcleo vem do IODeviceTree e é conferido com sysctl hw.perflevel0/1. ¦ Ticks per logical CPU via host_processor_info; each core's type comes from the IODeviceTree and is checked against sysctl hw.perflevel0/1. ¦ Ticks por CPU lógica vía host_processor_info; el tipo de cada núcleo viene del IODeviceTree y se verifica con sysctl hw.perflevel0/1.
  CPU %@ (%@): %@ ¦ CPU %@ (%@): %@ ¦ CPU %@ (%@): %@
  Memória de apps ¦ App memory ¦ Memoria de apps
  Wired ¦ Wired ¦ Wired
  Comprimida ¦ Compressed ¦ Comprimida
  Arquivos em cache ¦ Cached files ¦ Archivos en caché
  Detalhe da memória ¦ Memory breakdown ¦ Detalle de la memoria
  de %@ ¦ of %@ ¦ de %@
  Swap usado ¦ Swap used ¦ Swap usado
  Pressão de memória ¦ Memory pressure ¦ Presión de memoria
  evento: %@ ¦ event: %@ ¦ evento: %@
  Pressão % = 100 − memória disponível segundo o kernel (kern.memorystatus_level). Os eventos são os avisos do macOS; RAM ocupada, sozinha, não é pressão. ¦ Pressure % = 100 − memory available according to the kernel (kern.memorystatus_level). Events are macOS warnings; RAM in use, alone, is not pressure. ¦ Presión % = 100 − memoria disponible según el kernel (kern.memorystatus_level). Los eventos son los avisos de macOS; la RAM ocupada, por sí sola, no es presión.
  Gravar histórico neste Mac ¦ Record history on this Mac ¦ Grabar historial en este Mac
  Manter por ¦ Keep for ¦ Conservar durante
  1 dia ¦ 1 day ¦ 1 día
  30 dias ¦ 30 days ¦ 30 días
  Um resumo por minuto (CPU, memória, swap, disco, rede, térmico e os 10 processos com mais CPU e memória: nome, executável, diretório e origem; nunca argumentos ou ambiente), gravado em uma transação por minuto em ~/Library/Application Support/CoreScope/history.sqlite. Dados além da retenção são apagados automaticamente. Desligar interrompe a gravação; o que já foi salvo fica até você apagar. ¦ One summary per minute (CPU, memory, swap, disk, network, thermal and the 10 processes with the most CPU and memory: name, executable, folder and origin; never arguments or environment), written in one transaction per minute to ~/Library/Application Support/CoreScope/history.sqlite. Data past the retention is deleted automatically. Turning it off stops recording; what was saved stays until you delete it. ¦ Un resumen por minuto (CPU, memoria, swap, disco, red, térmico y los 10 procesos con más CPU y memoria: nombre, ejecutable, carpeta y origen; nunca argumentos ni entorno), escrito en una transacción por minuto en ~/Library/Application Support/CoreScope/history.sqlite. Los datos más antiguos que la retención se borran automáticamente. Desactivarlo detiene la grabación; lo guardado queda hasta que lo borres.
  Falha ao gravar: %@ ¦ Could not write: %@ ¦ Error al grabar: %@
  Armazenado ¦ Stored ¦ Almacenado
  %@ · %@ minutos desde %@ ¦ %@ · %@ minutes since %@ ¦ %@ · %@ minutos desde %@
  Nada salvo ¦ Nothing saved ¦ Nada guardado
  Apagar histórico… ¦ Delete history… ¦ Borrar historial…
  Apagar todo o histórico salvo? ¦ Delete all saved history? ¦ ¿Borrar todo el historial guardado?
  Apagar histórico ¦ Delete history ¦ Borrar historial
  Remove o arquivo do disco. A gravação continua se estiver ligada. ¦ Removes the file from disk. Recording continues if it is on. ¦ Elimina el archivo del disco. La grabación continúa si está activada.
  Consulta ausente ¦ Missing query ¦ Consulta ausente
  Operação desconhecida ¦ Unknown operation ¦ Operación desconocida
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
  Possível órfão: %@ ¦ Possible orphan: %@ ¦ Posible huérfano: %@
  %@ usa %@ de memória ¦ %@ is using %@ of memory ¦ %@ usa %@ de memoria
  %@ usa %@ de CPU ¦ %@ is using %@ CPU ¦ %@ usa %@ de CPU
  Acima de %@ há mais de %@. ¦ Above %@ for more than %@. ¦ Por encima de %@ durante más de %@.
  O macOS está sem memória livre e pode encerrar apps. Feche o que não estiver usando. ¦ macOS is out of free memory and may terminate apps. Quit what you are not using. ¦ macOS se quedó sin memoria libre y puede cerrar apps. Cierra lo que no estés usando.
  O macOS começou a comprimir memória e pode usar swap. ¦ macOS started compressing memory and may use swap. ¦ macOS empezó a comprimir memoria y puede usar swap.
  Maior consumo: %@ (%@) ¦ Largest user: %@ (%@) ¦ Mayor consumo: %@ (%@)
  Pressão de memória crítica ¦ Critical memory pressure ¦ Presión de memoria crítica
  Pressão de memória em atenção ¦ Memory pressure warning ¦ Aviso de presión de memoria
  O processo já não está em execução. ¦ The process is no longer running. ¦ El proceso ya no está en ejecución.
  Pressione o atalho… ¦ Press the shortcut… ¦ Pulsa el atajo…
  rodando há %@ ¦ running for %@ ¦ en ejecución hace %@
  Porta ¦ Port ¦ Puerto
  Livre ¦ Free ¦ Libre
  Nenhum processo seu escuta em :%@ ¦ None of your processes listens on :%@ ¦ Ninguno de tus procesos escucha en :%@
  Porta inválida ¦ Invalid port ¦ Puerto no válido
  Atalho global para buscar porta ¦ Global shortcut for port lookup ¦ Atajo global para buscar puerto
  Notificações ¦ Notifications ¦ Notificaciones
  Novo possível órfão ¦ New possible orphan ¦ Nuevo posible huérfano
  Processo pesado por muito tempo ¦ Process heavy for a long time ¦ Proceso pesado durante mucho tiempo
  Memória acima de ¦ Memory above ¦ Memoria por encima de
  CPU acima de ¦ CPU above ¦ CPU por encima de
  Por pelo menos ¦ For at least ¦ Durante al menos
  Pressão de memória do macOS (atenção/crítica) ¦ macOS memory pressure (warning/critical) ¦ Presión de memoria de macOS (aviso/crítica)
  O macOS está bloqueando as notificações do CoreScope. ¦ macOS is blocking CoreScope notifications. ¦ macOS está bloqueando las notificaciones de CoreScope.
  Abrir Ajustes do Sistema ¦ Open System Settings ¦ Abrir Ajustes del Sistema
  Desligadas por padrão e locais. No máximo uma notificação por processo (PID + início) por hora; processos protegidos ou de outros usuários nunca notificam. “Encerrar” envia SIGTERM pelo mesmo caminho do app, que revalida a identidade antes do sinal; nada é encerrado sem o seu clique. ¦ Off by default and local. At most one notification per process (PID + start) per hour; protected processes and other users' processes never notify. “Terminate” sends SIGTERM through the app's usual path, which revalidates the identity before signaling; nothing is terminated without your click. ¦ Desactivadas por defecto y locales. Como máximo una notificación por proceso (PID + inicio) por hora; los procesos protegidos o de otros usuarios nunca notifican. “Finalizar” envía SIGTERM por la misma vía de la app, que revalida la identidad antes de la señal; nada se finaliza sin tu clic.
  Atalho de porta ¦ Port shortcut ¦ Atajo de puerto
  Combinação ¦ Combination ¦ Combinación
  Outro app já usa esta combinação. Escolha outra. ¦ Another app already uses this combination. Pick another one. ¦ Otra app ya usa esta combinación. Elige otra.
  Abre o menu do CoreScope com o campo Porta em foco. Registrado com RegisterEventHotKey: não pede permissão de Acessibilidade e o app recebe só esta combinação. ¦ Opens the CoreScope menu with the Port field focused. Registered with RegisterEventHotKey: no Accessibility permission, and the app receives only this combination. ¦ Abre el menú de CoreScope con el campo Puerto enfocado. Registrado con RegisterEventHotKey: no pide permiso de Accesibilidad y la app recibe solo esta combinación.
  Núcleo %@ ¦ Core %@ ¦ Núcleo %@
  Núcleo %@ (%@) ¦ Core %@ (%@) ¦ Núcleo %@ (%@)
  pior: %@ ¦ worst: %@ ¦ peor: %@
  Sem projeto ¦ No project ¦ Sin proyecto
  Tokens ¦ Tokens ¦ Tokens
  Entrada ¦ Input ¦ Entrada
  Saída ¦ Output ¦ Salida
  Cache ¦ Cache ¦ Caché
  Cache de prompt: %@ gravados · %@ lidos ¦ Prompt cache: %@ written · %@ read ¦ Caché de prompt: %@ escritos · %@ leídos
  + %@ subagentes ¦ + %@ subagents ¦ + %@ subagentes
  Tokens desta sessão (subagentes incluídos), lidos do registro local do agente. ¦ Tokens used by this session (subagents included), read from the agent's local log. ¦ Tokens de esta sesión (subagentes incluidos), leídos del registro local del agente.
  Uso de tokens ¦ Token usage ¦ Uso de tokens
  Lendo registros locais dos agentes… ¦ Reading local agent logs… ¦ Leyendo registros locales de los agentes…
  Nenhum token registrado nos últimos 7 dias. ¦ No tokens recorded in the last 7 days. ¦ No hay tokens registrados en los últimos 7 días.
  Hoje ¦ Today ¦ Hoy
  Últimos 7 dias ¦ Last 7 days ¦ Últimos 7 días
  7 dias ¦ 7 days ¦ 7 días
  Contado dos registros locais do Claude Code e do Codex. Cache = tokens de prompt gravados e lidos do cache. Sem valores em dólar. ¦ Counted from Claude Code and Codex local logs. Cache = prompt tokens written to and read from the cache. No dollar amounts. ¦ Contado de los registros locales de Claude Code y Codex. Caché = tokens de prompt escritos y leídos de la caché. Sin importes en dólares.
  entrada %@ · saída %@ · cache %@ ¦ input %@ · output %@ · cache %@ ¦ entrada %@ · salida %@ · caché %@
  Hoje: %@ | 7 dias: %@ ¦ Today: %@ | 7 days: %@ ¦ Hoy: %@ | 7 días: %@
  + %@ outros projetos ¦ + %@ more projects ¦ + %@ proyectos más
  Por agente ¦ By agent ¦ Por agente
  Por projeto ¦ By project ¦ Por proyecto
  Por dia ¦ Per day ¦ Por día
  hoje ¦ today ¦ hoy
  Mostrar menos ¦ Show less ¦ Mostrar menos
  janela já reiniciou · aguardando novo uso para atualizar ¦ window already reset · waiting for new usage to update ¦ la ventana ya se reinició · esperando nuevo uso para actualizar
  %@ resets grátis ¦ %@ free resets ¦ %@ reinicios gratis
  via Codex %@ ¦ via Codex %@ ¦ vía Codex %@
  do log local %@ ¦ from local log %@ ¦ del registro local %@
  Atualizar ¦ Refresh ¦ Actualizar
  Pede o limite atual ao próprio Codex (atualiza sozinho a cada 5 min). ¦ Asks Codex itself for the current limit (refreshes every 5 min). ¦ Pide el límite actual al propio Codex (se actualiza cada 5 min).
  Ler o limite atual pelo Codex ¦ Read the current limit through Codex ¦ Leer el límite actual con Codex
  O Codex consulta sua conta com o login dele, como o app do Codex faz. O CoreScope não lê credenciais. Pode desligar em Ajustes › Agentes. ¦ Codex queries your account with its own login, as the Codex app does. CoreScope reads no credentials. Turn it off in Settings › Agents. ¦ Codex consulta tu cuenta con su propio inicio de sesión, como hace la app de Codex. CoreScope no lee credenciales. Desactívalo en Ajustes › Agentes.
  O Codex não grava mais o limite em disco. Com isto ligado, o CoreScope executa o app-server do próprio Codex a cada 5 minutos e pede o limite; o Codex consulta a OpenAI com o login dele. Nenhuma credencial é lida pelo CoreScope. ¦ Codex no longer stores its limit on disk. With this on, CoreScope runs Codex's own app-server every 5 minutes and asks for the limit; Codex queries OpenAI with its own login. CoreScope reads no credentials. ¦ Codex ya no guarda el límite en disco. Con esto activado, CoreScope ejecuta el app-server del propio Codex cada 5 minutos y pide el límite; Codex consulta a OpenAI con su propio inicio de sesión. CoreScope no lee credenciales.
  ativo %@ ¦ active %@ ¦ activo %@
  Roda dentro do app do Codex ¦ Runs inside the Codex app ¦ Se ejecuta dentro de la app de Codex
  Abrir no Codex ¦ Open in Codex ¦ Abrir en Codex
  Abre esta conversa no app do Codex ¦ Opens this conversation in the Codex app ¦ Abre esta conversación en la app de Codex
  Linha de comando ¦ Command line ¦ Línea de comandos
  Comando corescope ¦ corescope command ¦ Comando corescope
  Instalado em ~/.local/bin ¦ Installed in ~/.local/bin ¦ Instalado en ~/.local/bin
  Remover ¦ Remove ¦ Quitar
  Instalar ¦ Install ¦ Instalar
  corescope ports · free-port · kill-port 3000 · agents · orphans · top · kill PID --tree. Todos aceitam --json. Se o terminal não encontrar o comando, adicione ~/.local/bin ao PATH. ¦ corescope ports · free-port · kill-port 3000 · agents · orphans · top · kill PID --tree. All accept --json. If your terminal can't find the command, add ~/.local/bin to PATH. ¦ corescope ports · free-port · kill-port 3000 · agents · orphans · top · kill PID --tree. Todos aceptan --json. Si el terminal no encuentra el comando, añade ~/.local/bin al PATH.
  Servidor MCP para agentes ¦ MCP server for agents ¦ Servidor MCP para agentes
  Desativar ¦ Disable ¦ Desactivar
  Ativar ¦ Enable ¦ Activar
  Ativo ¦ Active ¦ Activo
  Não instalado ¦ Not installed ¦ No instalado
  Aponta para outra cópia do app ¦ Points to another copy of the app ¦ Apunta a otra copia de la app
  CLI do agente não encontrado. ¦ Agent CLI not found. ¦ No se encontró la CLI del agente.
  Comando corescope não encontrado no app. ¦ corescope command not found in the app. ¦ No se encontró el comando corescope en la app.
  Opcional. Registra corescope mcp no Claude Code e no Codex (pelos comandos mcp add deles). Os agentes podem consultar portas, porta livre, maiores processos, sessões e órfãos, e encerrar só o que a própria sessão iniciou — nunca outras sessões, outros usuários ou serviços do sistema. Tudo local, sem rede. ¦ Optional. Registers corescope mcp with Claude Code and Codex (through their own mcp add commands). Agents can query ports, a free port, top processes, sessions and orphans, and stop only what their own session started — never other sessions, other users or system services. Fully local, no network. ¦ Opcional. Registra corescope mcp en Claude Code y Codex (con sus propios comandos mcp add). Los agentes pueden consultar puertos, un puerto libre, los procesos más pesados, sesiones y huérfanos, y detener solo lo que inició su propia sesión — nunca otras sesiones, otros usuarios ni servicios del sistema. Todo local, sin red.
  %@ falharam: %@ ¦ %@ failed: %@ ¦ %@ fallaron: %@
  %@ itens do Docker serão removidos pelo Docker, sem volta. ¦ %@ Docker items will be removed by Docker, permanently. ¦ %@ elementos de Docker serán eliminados por Docker, sin vuelta atrás.
  %@ liberados em %@ itens. ¦ %@ freed from %@ items. ¦ %@ liberados en %@ elementos.
  %@ pastas vão para a Lixeira (recuperáveis até esvaziá-la). ¦ %@ folders go to the Trash (recoverable until you empty it). ¦ %@ carpetas van a la Papelera (recuperables hasta vaciarla).
  %@ selecionados · %@ ¦ %@ selected · %@ ¦ %@ seleccionados · %@
  Adicionar ¦ Add ¦ Añadir
  Adicionar pasta… ¦ Add folder… ¦ Añadir carpeta…
  Além das pastas que você adicionar, o CoreScope procura em ~/Developer, ~/Projects, ~/Code… e na pasta que contém cada projeto em que um agente, editor ou terminal está trabalhando agora. ¦ Besides the folders you add, CoreScope looks in ~/Developer, ~/Projects, ~/Code… and in the folder holding each project an agent, editor or terminal is working in right now. ¦ Además de las carpetas que añadas, CoreScope busca en ~/Developer, ~/Projects, ~/Code… y en la carpeta que contiene cada proyecto en el que un agente, editor o terminal está trabajando ahora.
  Analisando… ¦ Scanning… ¦ Analizando…
  Analisar ¦ Scan ¦ Analizar
  Analisar de novo ¦ Scan again ¦ Analizar de nuevo
  Cache de build ¦ Build cache ¦ Caché de build
  Caches de pacotes ¦ Package caches ¦ Cachés de paquetes
  Caches do Simulador ¦ Simulator caches ¦ Cachés del Simulador
  Caminho ausente ¦ Missing path ¦ Falta la ruta
  Caminho inválido ¦ Invalid path ¦ Ruta no válida
  Caminho não reconhecido para limpeza ¦ Not a recognized cleanup item ¦ No es un elemento de limpieza reconocido
  Caminho não é uma pasta real ¦ Not a real folder (symlink or changed) ¦ No es una carpeta real (enlace o cambió)
  Desmarcar ¦ Deselect ¦ Desmarcar
  Docker: %@ ¦ Docker: %@ ¦ Docker: %@
  Em uso por ¦ In use by ¦ En uso por
  Em uso · %@ ¦ In use · %@ ¦ En uso · %@
  Encontre node_modules, target/ do Rust, DerivedData, caches e imagens Docker sem uso. ¦ Find node_modules, Rust target/, DerivedData, caches and unused Docker images. ¦ Encuentra node_modules, target/ de Rust, DerivedData, cachés e imágenes de Docker sin uso.
  Feche ou pare o processo para poder limpar ¦ Close or stop the process to clean it ¦ Cierra o detén el proceso para poder limpiarlo
  Imagens sem contêiner ¦ Images without a container ¦ Imágenes sin contenedor
  Imagens órfãs (sem tag) ¦ Dangling images (untagged) ¦ Imágenes huérfanas (sin etiqueta)
  Item não existe mais ¦ Item no longer exists ¦ El elemento ya no existe
  Limpando %@ itens… ¦ Cleaning %@ items… ¦ Limpiando %@ elementos…
  Limpar ¦ Clean ¦ Limpiar
  Limpar %@ itens (%@)? ¦ Clean %@ items (%@)? ¦ ¿Limpiar %@ elementos (%@)?
  Limpar seleção ¦ Clear selection ¦ Quitar selección
  Limpar… ¦ Clean… ¦ Limpiar…
  Limpeza ¦ Cleanup ¦ Limpieza
  Motor de contêineres não encontrado ¦ Container engine not found ¦ No se encontró el motor de contenedores
  Nada para limpar nas pastas analisadas. ¦ Nothing to clean in the scanned folders. ¦ Nada que limpiar en las carpetas analizadas.
  Pastas ¦ Folders ¦ Carpetas
  Pastas vão para a Lixeira: dá para recuperá-las até esvaziar a Lixeira, e o espaço só é liberado depois disso. Itens que um processo está usando (servidor de dev, cargo, Xcode, um agente trabalhando no projeto) ficam bloqueados e são verificados de novo na hora de limpar. Dados do Docker são removidos pelo próprio Docker e não voltam: as imagens são baixadas de novo quando precisar. ¦ Folders go to the Trash: you can recover them until you empty it, and the space is freed only then. Items a process is using (dev server, cargo, Xcode, an agent working in the project) are locked and checked again right before cleaning. Docker data is removed by Docker itself and does not come back: images are pulled again when needed. ¦ Las carpetas van a la Papelera: puedes recuperarlas hasta vaciarla, y el espacio se libera solo entonces. Los elementos que usa un proceso (servidor de desarrollo, cargo, Xcode, un agente trabajando en el proyecto) quedan bloqueados y se comprueban de nuevo justo antes de limpiar. Los datos de Docker los elimina el propio Docker y no vuelven: las imágenes se descargan de nuevo cuando hagan falta.
  Projetos ¦ Projects ¦ Proyectos
  Remover pasta ¦ Remove folder ¦ Quitar carpeta
  Removido pelo Docker ¦ Removed by Docker ¦ Lo elimina Docker
  Seleciona as pastas que não mudam há mais de 30 dias ¦ Selects folders unchanged for more than 30 days ¦ Selecciona las carpetas sin cambios desde hace más de 30 días
  Selecionar tudo ¦ Select all ¦ Seleccionar todo
  Sem uso há 30+ dias ¦ Unused 30+ days ¦ Sin uso 30+ días
  Suporte a dispositivo ¦ Device support ¦ Soporte de dispositivo
  análise %@ (%@ s) ¦ scanned %@ (%@ s) ¦ análisis %@ (%@ s)
  recuperáveis em %@ itens ¦ reclaimable in %@ items ¦ recuperables en %@ elementos
  target/ do Rust ¦ Rust target/ ¦ target/ de Rust
  Última modificação ¦ Last modified ¦ Última modificación
  Limpando 1 item… ¦ Cleaning 1 item… ¦ Limpiando 1 elemento…
  Limpar 1 item (%@)? ¦ Clean 1 item (%@)? ¦ ¿Limpiar 1 elemento (%@)?
  1 pasta vai para a Lixeira (recuperável até esvaziá-la). ¦ 1 folder goes to the Trash (recoverable until you empty it). ¦ 1 carpeta va a la Papelera (recuperable hasta vaciarla).
  1 item do Docker será removido pelo Docker, sem volta. ¦ 1 Docker item will be removed by Docker, permanently. ¦ 1 elemento de Docker será eliminado por Docker, sin vuelta atrás.
  recuperáveis em 1 item ¦ reclaimable in 1 item ¦ recuperables en 1 elemento
  %@ liberados em 1 item. ¦ %@ freed from 1 item. ¦ %@ liberados en 1 elemento.
  Não foi possível limpar %@ ¦ Could not clean %@ ¦ No se pudo limpiar %@
  %@ parece travado ¦ %@ looks stuck ¦ %@ parece atascado
  Rodando %@ há %@ min, sem novas mensagens ¦ Running %@ for %@ min, no new messages ¦ Ejecutando %@ desde hace %@ min, sin mensajes nuevos
  Esperando %@ há %@ min: pode estar pedindo uma entrada ¦ Waiting on %@ for %@ min: it may be asking for input ¦ Esperando a %@ desde hace %@ min: puede estar pidiendo una entrada
  Sem atividade há %@ min ¦ No activity for %@ min ¦ Sin actividad desde hace %@ min
  Parece travada · %@ min ¦ Looks stuck · %@ min ¦ Parece atascada · %@ min
  Comando longo · %@ min ¦ Long command · %@ min ¦ Comando largo · %@ min
  Agente parece travado ¦ Agent looks stuck ¦ El agente parece atascado
  Travado após ¦ Stuck after ¦ Atascado tras
  %@ min sem atividade ¦ %@ min without activity ¦ %@ min sin actividad
  Uma sessão ocupada (Claude Code, Codex) que não escreve na própria transcrição por esse tempo. Se um comando iniciado nesta vez está usando CPU, é só um comando longo; se está parado, pode estar esperando uma entrada. Vale também para o selo na página Agentes. Lê apenas datas de modificação, nunca o conteúdo. ¦ A busy session (Claude Code, Codex) that has not written to its transcript for this long. If a command started in this turn is using CPU, it is just a long command; if it sits idle, it may be waiting for input. Also drives the badge on the Agents page. Reads modification dates only, never content. ¦ Una sesión ocupada (Claude Code, Codex) que no escribe en su transcripción durante ese tiempo. Si un comando iniciado en este turno usa CPU, solo es un comando largo; si está parado, puede estar esperando una entrada. También controla la insignia de la página Agentes. Solo lee fechas de modificación, nunca el contenido.
  Destino inválido ¦ Invalid target ¦ Destino no válido
  porta aberta ¦ port open ¦ puerto abierto
  %@ fora do ar ¦ %@ is down ¦ %@ está caído
  %@ voltou ¦ %@ is back ¦ %@ volvió
  sem resposta ¦ no answer ¦ sin respuesta
  sem resposta em 5 s ¦ no answer in 5 s ¦ sin respuesta en 5 s
  sem resposta em 3 s ¦ no answer in 3 s ¦ sin respuesta en 3 s
  conexão recusada ¦ connection refused ¦ conexión rechazada
  host não encontrado ¦ host not found ¦ host no encontrado
  sem rede ¦ no network ¦ sin red
  certificado TLS inválido ¦ invalid TLS certificate ¦ certificado TLS no válido
  porta inválida ¦ invalid port ¦ puerto no válido
  No ar ¦ Up ¦ Activo
  Respondeu com erro ¦ Answered with an error ¦ Respondió con error
  Fora do ar ¦ Down ¦ Caído
  Adicionar serviço ¦ Add service ¦ Añadir servicio
  Nome ¦ Name ¦ Nombre
  URL ou porta: 3000, localhost:5432, https://…/health ¦ URL or port: 3000, localhost:5432, https://…/health ¦ URL o puerto: 3000, localhost:5432, https://…/health
  Salvar ¦ Save ¦ Guardar
  Destino fora deste Mac: o CoreScope vai acessar %@ a cada 30 s. ¦ Target outside this Mac: CoreScope will contact %@ every 30 s. ¦ Destino fuera de este Mac: CoreScope accederá a %@ cada 30 s.
  Portas abertas agora: ¦ Open ports now: ¦ Puertos abiertos ahora:
  Nenhum serviço monitorado. Adicione uma URL de health check ou uma porta (API local, banco, staging). ¦ No services watched. Add a health check URL or a port (local API, database, staging). ¦ Ningún servicio vigilado. Añade una URL de health check o un puerto (API local, base de datos, staging).
  Serviços ¦ Services ¦ Servicios
  Verificar agora ¦ Check now ¦ Comprobar ahora
  Notificar quando um serviço cair ou voltar ¦ Notify when a service goes down or comes back ¦ Notificar cuando un servicio caiga o vuelva
  Verifica a cada 30 s enquanto o CoreScope está aberto: HTTP GET (2xx/3xx no ar, 4xx respondeu com erro, 5xx ou sem resposta fora do ar) ou conexão TCP na porta. Sem cookies nem cache; só os destinos que você adicionou são acessados. Alerta depois de duas falhas seguidas. ¦ Checked every 30 s while CoreScope is open: HTTP GET (2xx/3xx up, 4xx answered with an error, 5xx or no answer down) or a TCP connection to the port. No cookies or cache; only the targets you added are contacted. Alerts after two failures in a row. ¦ Se comprueba cada 30 s mientras CoreScope está abierto: HTTP GET (2xx/3xx activo, 4xx respondió con error, 5xx o sin respuesta caído) o una conexión TCP al puerto. Sin cookies ni caché; solo se contactan los destinos que añadiste. Avisa tras dos fallos seguidos.
  Verificando… ¦ Checking… ¦ Comprobando…
  Abrir no navegador ¦ Open in browser ¦ Abrir en el navegador
  Editar ¦ Edit ¦ Editar
  Perfis ¦ Profiles ¦ Perfiles
  %@ de %@ rodando ¦ %@ of %@ running ¦ %@ de %@ en ejecución
  %@ iniciado. ¦ %@ started. ¦ %@ iniciado.
  %@: %@ ¦ %@: %@ ¦ %@: %@
  Abrir log ¦ Open log ¦ Abrir log
  Adicionar comando ¦ Add command ¦ Añadir comando
  Apagar ¦ Delete ¦ Eliminar
  Apagar o perfil %@? ¦ Delete the %@ profile? ¦ ¿Eliminar el perfil %@?
  Apagar perfil ¦ Delete profile ¦ Eliminar perfil
  Comando, ex.: npm run dev ¦ Command, e.g. npm run dev ¦ Comando, p. ej. npm run dev
  Comandos ¦ Commands ¦ Comandos
  Contêiner %@ não encontrado ¦ Container %@ not found ¦ Contenedor %@ no encontrado
  Envia SIGTERM aos processos que o CoreScope iniciou para este perfil (e aos filhos deles) e para os contêineres do perfil. ¦ Sends SIGTERM to the processes CoreScope started for this profile (and their children) and stops the profile's containers. ¦ Envía SIGTERM a los procesos que CoreScope inició para este perfil (y a sus hijos) y detiene los contenedores del perfil.
  Escolher… ¦ Choose… ¦ Elegir…
  Iniciando %@… ¦ Starting %@… ¦ Iniciando %@…
  Iniciar ¦ Start ¦ Iniciar
  Mostrar logs no Finder ¦ Show logs in Finder ¦ Mostrar logs en el Finder
  Nenhum contêiner encontrado. ¦ No containers found. ¦ No se encontraron contenedores.
  Nenhum perfil ainda. Crie um com os comandos que você roda todo dia (npm run dev, php artisan serve…) e os contêineres do projeto. ¦ No profiles yet. Create one with the commands you run every day (npm run dev, php artisan serve…) and the project's containers. ¦ Aún no hay perfiles. Crea uno con los comandos que ejecutas a diario (npm run dev, php artisan serve…) y los contenedores del proyecto.
  Novo perfil ¦ New profile ¦ Nuevo perfil
  Não foi possível criar o log ¦ Could not create the log ¦ No se pudo crear el log
  O comando terminou logo ao iniciar; veja o log ¦ The command exited right away; see the log ¦ El comando terminó al iniciar; mira el log
  Os comandos rodam no seu shell de login, na pasta do perfil, com a saída em ~/Library/Application Support/CoreScope/logs. Parar encerra só os processos que o CoreScope iniciou (com a mesma verificação de identidade do resto do app) e para os contêineres do perfil. ¦ Commands run in your login shell, in the profile's folder, with output in ~/Library/Application Support/CoreScope/logs. Stop ends only the processes CoreScope started (with the same identity checks as the rest of the app) and stops the profile's containers. ¦ Los comandos se ejecutan en tu shell de inicio de sesión, en la carpeta del perfil, con la salida en ~/Library/Application Support/CoreScope/logs. Detener finaliza solo los procesos que CoreScope inició (con la misma verificación de identidad que el resto de la app) y detiene los contenedores del perfil.
  Parar %@? ¦ Stop %@? ¦ ¿Detener %@?
  Pasta ¦ Folder ¦ Carpeta
  Pasta não encontrada ¦ Folder not found ¦ Carpeta no encontrada
  Só a configuração é apagada; nada que esteja rodando é encerrado. ¦ Only the settings are deleted; nothing running is stopped. ¦ Solo se elimina la configuración; no se detiene nada en ejecución.
  Um clique para subir (ou derrubar) o ambiente de um projeto: comandos na pasta dele e os contêineres de que ele precisa. ¦ One click to bring a project's environment up (or down): commands in its folder and the containers it needs. ¦ Un clic para levantar (o bajar) el entorno de un proyecto: comandos en su carpeta y los contenedores que necesita.
  não encontrado ¦ not found ¦ no encontrado
  Comando ¦ Command ¦ Comando
  Parar tudo, inclusive compartilhados ¦ Stop everything, including shared ¦ Detener todo, incluso compartidos
  Envia SIGTERM aos processos que o CoreScope iniciou para este perfil (e aos filhos deles). ¦ Sends SIGTERM to the processes CoreScope started for this profile (and their children). ¦ Envía SIGTERM a los procesos que CoreScope inició para este perfil (y a sus hijos).
  Para: %@ ¦ Stops: %@ ¦ Detiene: %@
  Mantém %@: em uso pelo perfil %@ ¦ Keeps %@: in use by the %@ profile ¦ Mantiene %@: en uso por el perfil %@
  Mantém %@: já estava rodando quando o perfil foi iniciado ¦ Keeps %@: it was already running when the profile started ¦ Mantiene %@: ya estaba en ejecución cuando se inició el perfil
  As pastas mudaram desde a última análise. ¦ The folders changed since the last scan. ¦ Las carpetas cambiaron desde el último análisis.
  Resultado de %@: pode estar desatualizado. Analise de novo para ver o estado atual. ¦ Result from %@: it may be out of date. Scan again to see the current state. ¦ Resultado de %@: puede estar desactualizado. Analiza de nuevo para ver el estado actual.
  A análise percorre as pastas de projeto e pode levar alguns segundos; nada é lido até você clicar em Analisar. ¦ Scanning walks your project folders and can take a few seconds; nothing is read until you click Scan. ¦ El análisis recorre las carpetas de proyecto y puede tardar unos segundos; no se lee nada hasta que pulses Analizar.
  %@ chaves ¦ %@ keys ¦ %@ claves
  + %@ bancos ¦ + %@ databases ¦ + %@ bases de datos
  Bancos ¦ Databases ¦ Bases de datos
  Conexão recusada ¦ Connection refused ¦ Conexión rechazada
  Conexões ¦ Connections ¦ Conexiones
  Consultas acima do long_query_time desde que o servidor subiu ¦ Queries over long_query_time since the server started ¦ Consultas por encima de long_query_time desde que arrancó el servidor
  Consultas rodando há mais de 5 s ¦ Queries running for more than 5 s ¦ Consultas en ejecución desde hace más de 5 s
  Consultas só de leitura em 127.0.0.1, pelo protocolo de cada banco. O CoreScope nunca pede, guarda ou lê senhas: conecta apenas quando o servidor aceita acesso local sem senha (MySQL root sem senha, PostgreSQL com trust para o seu usuário, Redis sem AUTH) e, se não, mostra que pede senha. Cada consulta tem limite de tempo também no servidor. ¦ Read-only queries on 127.0.0.1, over each database's own protocol. CoreScope never asks for, stores or reads passwords: it connects only when the server allows passwordless local access (MySQL root without a password, PostgreSQL trust for your user, Redis without AUTH) and otherwise shows that a password is required. Every query also has a time limit on the server. ¦ Consultas de solo lectura en 127.0.0.1, con el protocolo de cada base de datos. CoreScope nunca pide, guarda ni lee contraseñas: solo se conecta cuando el servidor acepta acceso local sin contraseña (MySQL root sin contraseña, PostgreSQL con trust para tu usuario, Redis sin AUTH) y, si no, indica que pide contraseña. Cada consulta tiene también un límite de tiempo en el servidor.
  Entradas no SLOWLOG do Redis ¦ Entries in Redis's SLOWLOG ¦ Entradas en el SLOWLOG de Redis
  Erro ¦ Error ¦ Error
  Lentas ¦ Slow ¦ Lentas
  MySQL/MariaDB, PostgreSQL e Redis encontrados em processos e contêineres locais. ¦ MySQL/MariaDB, PostgreSQL and Redis found in local processes and containers. ¦ MySQL/MariaDB, PostgreSQL y Redis encontrados en procesos y contenedores locales.
  Nenhum MySQL, PostgreSQL ou Redis local em execução. ¦ No local MySQL, PostgreSQL or Redis running. ¦ Ningún MySQL, PostgreSQL o Redis local en ejecución.
  Não é MySQL ¦ Not a MySQL server ¦ No es un servidor MySQL
  Não é PostgreSQL ¦ Not a PostgreSQL server ¦ No es un servidor PostgreSQL
  Não é Redis ¦ Not a Redis server ¦ No es un servidor Redis
  Pacote grande demais ¦ Packet too large ¦ Paquete demasiado grande
  Pede senha ¦ Needs a password ¦ Pide contraseña
  Pede senha: o CoreScope não usa senhas, então não lê este servidor. ¦ Needs a password: CoreScope does not use passwords, so it does not read this server. ¦ Pide contraseña: CoreScope no usa contraseñas, así que no lee este servidor.
  Procurando bancos locais… ¦ Looking for local databases… ¦ Buscando bases de datos locales…
  Resposta grande demais ¦ Reply too large ¦ Respuesta demasiado grande
  Resposta inválida ¦ Invalid reply ¦ Respuesta no válida
  Sem resposta ¦ No answer ¦ Sin respuesta
  Slowlog ¦ Slowlog ¦ Slowlog
  contêiner ¦ container ¦ contenedor
  no ar há %@ ¦ up for %@ ¦ activo desde hace %@
  Abrir no Terminal ¦ Open in Terminal ¦ Abrir en Terminal
  Acesso negado: o ssh precisa de uma chave (o CoreScope não usa senhas) ¦ Access denied: ssh needs a key (CoreScope does not use passwords) ¦ Acceso denegado: ssh necesita una clave (CoreScope no usa contraseñas)
  Adicionar máquina ¦ Add machine ¦ Añadir máquina
  Alias do ~/.ssh/config ou usuario@host ¦ Alias from ~/.ssh/config or user@host ¦ Alias de ~/.ssh/config o usuario@host
  Carga ¦ Load ¦ Carga
  Carga / núcleos ¦ Load / cores ¦ Carga / núcleos
  Chave do host desconhecida: conecte uma vez pelo Terminal para confirmá-la ¦ Unknown host key: connect once from Terminal to confirm it ¦ Clave de host desconocida: conéctate una vez desde Terminal para confirmarla
  Disco / ¦ Disk / ¦ Disco /
  Do seu ~/.ssh/config: ¦ From your ~/.ssh/config: ¦ De tu ~/.ssh/config:
  Falhou (código %@) ¦ Failed (code %@) ¦ Falló (código %@)
  Host não encontrado ¦ Host not found ¦ Host no encontrado
  Máquinas ¦ Machines ¦ Máquinas
  Média de 1 min; %@ núcleos ¦ 1-minute average; %@ cores ¦ Media de 1 min; %@ núcleos
  Nenhuma máquina. Adicione servidores que você acessa por ssh com chave para ver carga, memória, disco e processos. ¦ No machines. Add servers you reach over ssh with a key to see load, memory, disk and processes. ¦ Ninguna máquina. Añade servidores a los que accedes por ssh con clave para ver carga, memoria, disco y procesos.
  Sem resposta em 15 s ¦ No answer in 15 s ¦ Sin respuesta en 15 s
  Usa o seu próprio ssh em BatchMode: chaves e agente ficam com o ssh, nada pede senha e um host com chave desconhecida falha em vez de ser aceito. O comando remoto só lê (uname, carga, memória, df, ps, docker ps). Atualiza a cada 60 s enquanto esta página está aberta. ¦ Uses your own ssh in BatchMode: keys and agent stay with ssh, nothing prompts for a password, and a host with an unknown key fails instead of being accepted. The remote command only reads (uname, load, memory, df, ps, docker ps). Refreshes every 60 s while this page is open. ¦ Usa tu propio ssh en BatchMode: las claves y el agente se quedan en ssh, nada pide contraseña y un host con clave desconocida falla en vez de aceptarse. El comando remoto solo lee (uname, carga, memoria, df, ps, docker ps). Se actualiza cada 60 s mientras esta página está abierta.
  lido %@ (%@ s) ¦ read %@ (%@ s) ¦ leído %@ (%@ s)
  %@ está gastando bateria ¦ %@ is draining the battery ¦ %@ está gastando batería
  %@ por 5 min na bateria (%@%%) ¦ %@ for 5 min on battery (%@%%) ¦ %@ durante 5 min con batería (%@%%)
  Acima de ¦ Above ¦ Por encima de
  Carregando ¦ Charging ¦ Cargando
  Carregando · cheia em %@ ¦ Charging · full in %@ ¦ Cargando · llena en %@
  Energia ¦ Energy ¦ Energía
  Este Mac usa só energia da tomada. ¦ This Mac runs on wall power only. ¦ Este Mac solo usa corriente.
  Na bateria ¦ On battery ¦ Con batería
  Na bateria · %@ restantes ¦ On battery · %@ left ¦ Con batería · quedan %@
  Na tomada, sem carregar ¦ On AC power, not charging ¦ Enchufado, sin cargar
  Nenhuma sessão de agente rodando. ¦ No agent sessions running. ¦ Ninguna sesión de agente en ejecución.
  Notificar quando um agente gastar bateria ¦ Notify when an agent drains the battery ¦ Notificar cuando un agente gaste batería
  Processos que mais gastam ¦ Processes drawing the most ¦ Procesos que más consumen
  Sem bateria ¦ No battery ¦ Sin batería
  Sem leitura de energia por processo neste macOS. ¦ No per-process energy on this macOS. ¦ Sin lectura de energía por proceso en este macOS.
  Sessões de agente ¦ Agent sessions ¦ Sesiones de agente
  Soma da sessão e de tudo que ela iniciou ¦ The session plus everything it started ¦ La sesión más todo lo que inició
  Só na bateria: avisa quando uma sessão de agente, somando os processos que ela iniciou, passa do limite por 5 minutos (no máximo uma vez por hora por sessão). ¦ On battery only: alerts when an agent session, counting the processes it started, stays above the limit for 5 minutes (at most once an hour per session). ¦ Solo con batería: avisa cuando una sesión de agente, sumando los procesos que inició, supera el límite durante 5 minutos (como máximo una vez por hora por sesión).
  Watts estimados pelo macOS para cada processo (energia de CPU e GPU atribuída a ele, rusage v6). Não inclui tela, rádios e outros componentes, então a soma fica abaixo do consumo total do Mac. ¦ Watts macOS estimates for each process (CPU and GPU energy billed to it, rusage v6). Display, radios and other components are not included, so the sum stays below the Mac's total draw. ¦ Vatios que macOS estima para cada proceso (energía de CPU y GPU atribuida, rusage v6). No incluye pantalla, radios ni otros componentes, así que la suma queda por debajo del consumo total del Mac.
  processos agora ¦ processes now ¦ procesos ahora
  Agentes podem usar o app pelo MCP ¦ Agents can use the app through MCP ¦ Los agentes pueden usar la app por MCP
  Perfis (criar, iniciar, parar, logs), Serviços, Máquinas, limpeza (analisar e mover para a Lixeira o que a análise encontrou) e ajustes de notificação. Pelo socket local do app, só para o seu usuário. O agente pede a sua aprovação antes de cada ação. ¦ Profiles (create, start, stop, logs), Services, Machines, cleanup (scan, and move to the Trash what the scan found) and notification settings. Through the app's local socket, for your user only. The agent asks for your approval before each action. ¦ Perfiles (crear, iniciar, detener, logs), Servicios, Máquinas, limpieza (analizar y mover a la Papelera lo que encontró el análisis) y ajustes de notificación. Por el socket local de la app, solo para tu usuario. El agente pide tu aprobación antes de cada acción.
  Uma análise ou limpeza já está em andamento ¦ A scan or cleanup is already running ¦ Ya hay un análisis o limpieza en curso
  O perfil já está iniciando ou parando ¦ The profile is already starting or stopping ¦ El perfil ya se está iniciando o deteniendo
  ao parar ¦ on stop ¦ al detener
  Ao parar ¦ On stop ¦ Al detener
  ao parar: %@ ¦ on stop: %@ ¦ al detener: %@
  Opcional, ex.: make env-down ¦ Optional, e.g. make env-down ¦ Opcional, p. ej. make env-down
  concluído %@ ¦ completed %@ ¦ completado %@
  falhou · saída %@ ¦ failed · exit %@ ¦ falló · salida %@
  Comando de preparação: terminou com sucesso (saída 0) e conta como ativo enquanto o perfil está iniciado. ¦ Setup command: it finished successfully (exit 0) and counts as up while the profile is started. ¦ Comando de preparación: terminó con éxito (salida 0) y cuenta como activo mientras el perfil está iniciado.
  %@: o comando ao parar passou de 2 min ¦ %@: the stop command took more than 2 min ¦ %@: el comando al detener tardó más de 2 min
  %@: o comando ao parar saiu com %@ ¦ %@: the stop command exited with %@ ¦ %@: el comando al detener salió con %@
  concluído ¦ completed ¦ completado
  %@ processos ¦ %@ processes ¦ %@ procesos
  Abrir .corescope.yml ¦ Open .corescope.yml ¦ Abrir .corescope.yml
  Definido no arquivo do projeto: edite o arquivo para mudar o perfil. ¦ Defined in the project file: edit the file to change the profile. ¦ Definido en el archivo del proyecto: edita el archivo para cambiar el perfil.
  Logs ¦ Logs ¦ Logs
  Procurando logs… ¦ Looking for logs… ¦ Buscando logs…
  Nenhum log encontrado nos projetos conhecidos. ¦ No logs found in the known projects. ¦ No se encontraron logs en los proyectos conocidos.
  Erros ¦ Errors ¦ Errores
  Busca ¦ Search ¦ Búsqueda
  Buscar nos logs do projeto ¦ Search the project's logs ¦ Buscar en los logs del proyecto
  Erros recentes · %@ ¦ Recent errors · %@ ¦ Errores recientes · %@
  todos os projetos ¦ all projects ¦ todos los proyectos
  Escolha um log ¦ Choose a log ¦ Elige un log
  Escolha um log à esquerda, ou clique em Erros num projeto. ¦ Choose a log on the left, or click Errors on a project. ¦ Elige un log a la izquierda, o pulsa Errores en un proyecto.
  Nenhum erro recente. ¦ No recent errors. ¦ Ningún error reciente.
  Nada encontrado. ¦ Nothing found. ¦ No se encontró nada.
  Log não encontrado ¦ Log not found ¦ Log no encontrado
  Nome de contêiner inválido ¦ Invalid container name ¦ Nombre de contenedor no válido
  Fonte ausente ¦ Missing source ¦ Falta la fuente
  Iniciar o contêiner %@ ¦ Start the %@ container ¦ Iniciar el contenedor %@
  Política de reinício: o Docker sobe o contêiner de novo sozinho ¦ Restart policy: Docker brings the container back up by itself ¦ Política de reinicio: Docker vuelve a levantar el contenedor solo
  imagem de %@ ¦ image from %@ ¦ imagen de %@
  Mostrar parados ¦ Show stopped ¦ Mostrar detenidos
  Sem projeto compose ¦ No compose project ¦ Sin proyecto compose
  Iniciar todos ¦ Start all ¦ Iniciar todos
  Parar todos ¦ Stop all ¦ Detener todos
  Parar os contêineres de %@ ¦ Stop the containers of %@ ¦ Detener los contenedores de %@
  Volumes ¦ Volumes ¦ Volúmenes
  %@ sem nenhum contêiner (%@). Remover um volume apaga os dados dele; faça pelo Docker se tiver certeza. ¦ %@ not used by any container (%@). Removing a volume deletes its data; do it through Docker if you are sure. ¦ %@ sin ningún contenedor (%@). Eliminar un volumen borra sus datos; hazlo con Docker si estás seguro.
  sem uso ¦ unused ¦ sin uso
  %@ contêiner(es) ¦ %@ container(s) ¦ %@ contenedor(es)
  Mostrar todos (%@) ¦ Show all (%@) ¦ Mostrar todos (%@)
  Não foi possível ler ~/.claude/settings.json ¦ Could not read ~/.claude/settings.json ¦ No se pudo leer ~/.claude/settings.json
  ~/.claude/settings.json não é um JSON válido; corrija o arquivo antes. ¦ ~/.claude/settings.json is not valid JSON; fix the file first. ¦ ~/.claude/settings.json no es un JSON válido; corrige el archivo antes.
  Aguardando capacidade ¦ Waiting for capacity ¦ Esperando capacidad
  O projeto pede que agentes esperem a máquina ter folga antes de comandos pesados (.corescope.yml › agents.wait_for_capacity). O comando começa sozinho quando a CPU e a memória normalizarem. ¦ The project asks agents to wait for the Mac to have room before heavy commands (.corescope.yml › agents.wait_for_capacity). The command starts by itself once CPU and memory are back to normal. ¦ El proyecto pide que los agentes esperen a que la máquina tenga margen antes de comandos pesados (.corescope.yml › agents.wait_for_capacity). El comando empieza solo cuando la CPU y la memoria se normalicen.
  Claude Code espera a máquina ter folga antes de comandos pesados ¦ Claude Code waits for the Mac to have room before heavy commands ¦ Claude Code espera a que la máquina tenga margen antes de comandos pesados
  Instala um hook em ~/.claude/settings.json (com backup) que roda corescope gate antes de cada comando: nos projetos cujo .corescope.yml define agents.wait_for_capacity, builds e testes esperam a CPU e a memória normalizarem. Nos outros não faz nada. Codex e outros agentes usam a ferramenta MCP wait_for_capacity. ¦ Installs a hook in ~/.claude/settings.json (with a backup) that runs corescope gate before each command: in projects whose .corescope.yml sets agents.wait_for_capacity, builds and tests wait for CPU and memory to settle. Elsewhere it does nothing. Codex and other agents use the MCP tool wait_for_capacity. ¦ Instala un hook en ~/.claude/settings.json (con copia de seguridad) que ejecuta corescope gate antes de cada comando: en los proyectos cuyo .corescope.yml define agents.wait_for_capacity, las compilaciones y pruebas esperan a que la CPU y la memoria se normalicen. En los demás no hace nada. Codex y otros agentes usan la herramienta MCP wait_for_capacity.
  Modo economia para agentes ¦ Economy mode for agents ¦ Modo ahorro para agentes
  Na bateria, os processos que sessões de agente iniciam e que estão usando CPU (builds, testes) rodam com prioridade de segundo plano do macOS, cedendo CPU e disco ao que você está fazendo. Servidores com porta aberta ficam como estão. Volta ao normal na tomada ou ao desligar. ¦ On battery, processes that agent sessions start and that are using CPU (builds, tests) run at macOS background priority, yielding CPU and disk to what you are doing. Servers with an open port are left as they are. Back to normal on AC power or when turned off. ¦ Con batería, los procesos que inician las sesiones de agente y que usan CPU (compilaciones, pruebas) se ejecutan con prioridad de segundo plano de macOS, cediendo CPU y disco a lo que estás haciendo. Los servidores con puerto abierto se quedan como están. Vuelve a la normalidad enchufado o al desactivarlo.
  %@ processos de agentes em segundo plano agora ¦ %@ agent processes in the background now ¦ %@ procesos de agentes en segundo plano ahora
  Worktrees ¦ Worktrees ¦ Worktrees
  Bloqueado no git (git worktree lock) ¦ Locked in git (git worktree lock) ¦ Bloqueado en git (git worktree lock)
  O git não conseguiu ler este worktree ¦ git could not read this worktree ¦ git no pudo leer este worktree
  %@ alterações não commitadas ¦ %@ uncommitted changes ¦ %@ cambios sin confirmar
  Sessões no mesmo diretório ¦ Sessions in the same folder ¦ Sesiones en la misma carpeta
  Várias sessões de agente no mesmo diretório de trabalho podem sobrescrever os arquivos umas das outras e disputar portas e o servidor de dev. Dê a cada uma um git worktree próprio. ¦ Several agent sessions in one working tree can overwrite each other's files and fight over ports and the dev server. Give each its own git worktree. ¦ Varias sesiones de agente en el mismo árbol de trabajo pueden sobrescribir los archivos de las otras y disputarse puertos y el servidor de desarrollo. Da a cada una su propio git worktree.
  Acessível pela rede ¦ Reachable from the network ¦ Accesible desde la red
  Nada seu escuta além do localhost. ¦ Nothing of yours listens beyond localhost. ¦ Nada tuyo escucha más allá de localhost.
  alto ¦ high ¦ alto
  médio ¦ medium ¦ medio
  baixo ¦ low ¦ bajo
  Portas abertas em todas as interfaces (0.0.0.0) podem ser acessadas por outros na mesma rede: café, coworking, escritório. Bancos e caches costumam vir sem senha em desenvolvimento. ¦ Ports open on all interfaces (0.0.0.0) can be reached by others on the same network: cafés, coworking, offices. Databases and caches often have no password in development. ¦ Los puertos abiertos en todas las interfaces (0.0.0.0) pueden ser accedidos por otros en la misma red: cafés, coworking, oficinas. Las bases de datos y cachés suelen no tener contraseña en desarrollo.
  Portas preferidas dos projetos ¦ Projects' preferred ports ¦ Puertos preferidos de los proyectos
  Achar porta livre ¦ Find a free port ¦ Buscar puerto libre
  Copiar ¦ Copy ¦ Copiar
  Nenhum .corescope.yml com `ports:`. Declare as portas do projeto (web: 8000, vite: 5173) para ver conflitos aqui. ¦ No .corescope.yml with `ports:`. Declare the project's ports (web: 8000, vite: 5173) to see conflicts here. ¦ Ningún .corescope.yml con `ports:`. Declara los puertos del proyecto (web: 8000, vite: 5173) para ver conflictos aquí.
  livre ¦ free ¦ libre
  em uso pelo projeto ¦ in use by the project ¦ en uso por el proyecto
  ocupada por %@ ¦ taken by %@ ¦ ocupado por %@
  livre: :%@ ¦ free: :%@ ¦ libre: :%@
  Disco %@ em %@%% ¦ Disk %@ at %@%% ¦ Disco %@ al %@%%
  Carga %@ em %@ núcleos ¦ Load %@ on %@ cores ¦ Carga %@ en %@ núcleos
  Serviços do systemd com falha: %@ ¦ Failed systemd units: %@ ¦ Servicios de systemd con fallo: %@
  Serviços do systemd com falha: ¦ Failed systemd units: ¦ Servicios de systemd con fallo:
  Ver por que falhou (systemctl status e journalctl, só leitura) ¦ See why it failed (systemctl status and journalctl, read-only) ¦ Ver por qué falló (systemctl status y journalctl, solo lectura)
  Nome de serviço inválido ¦ Invalid unit name ¦ Nombre de servicio no válido
  Lendo status e journal… ¦ Reading status and journal… ¦ Leyendo estado y journal…
  Só leitura: roda systemctl status e journalctl pelo seu ssh em BatchMode, sem sudo. As dicas só explicam; o CoreScope nunca altera o servidor. ¦ Read-only: runs systemctl status and journalctl through your ssh in BatchMode, without sudo. Hints only explain; CoreScope never changes the server. ¦ Solo lectura: ejecuta systemctl status y journalctl con tu ssh en BatchMode, sin sudo. Las pistas solo explican; CoreScope nunca cambia el servidor.
  Serviço não encontrado nesta máquina (pode ter sido removido desde a última leitura). ¦ Unit not found on this machine (it may have been removed since the last reading). ¦ Servicio no encontrado en esta máquina (puede haberse eliminado desde la última lectura).
  O journald não mostrou nada a este usuário do ssh: para ler o log dos serviços do sistema ele precisa estar no grupo adm ou systemd-journal. ¦ journald showed nothing to this ssh user: to read system units' logs it needs to be in the adm or systemd-journal group. ¦ journald no mostró nada a este usuario de ssh: para leer el log de los servicios del sistema necesita estar en el grupo adm o systemd-journal.
  Erros da última execução ¦ Errors from the last run ¦ Errores de la última ejecución
  Nenhuma linha de erro na última execução. ¦ No error lines in the last run. ¦ Ninguna línea de error en la última ejecución.
  Exemplos ¦ Examples ¦ Ejemplos
  Saída completa ¦ Full output ¦ Salida completa
  Um arquivo do logrotate cita um usuário que não existe mais — normalmente sobra de um usuário de site removido (o Laravel Forge deixa /etc/logrotate.d/forge-*). O logrotate o pula e a execução falha; remova ou corrija ¦ A logrotate config names a user that no longer exists — usually left behind when a site user was deleted (Laravel Forge leaves /etc/logrotate.d/forge-*). logrotate skips it and the run fails; remove or fix ¦ Un archivo de logrotate nombra a un usuario que ya no existe — normalmente restos de un usuario de sitio eliminado (Laravel Forge deja /etc/logrotate.d/forge-*). logrotate lo omite y la ejecución falla; elimina o corrige
  Dois arquivos do logrotate rodam o mesmo log e o logrotate recusa o segundo (muitas vezes um arquivo antigo do Forge ao lado de um novo). Mantenha só um de ¦ Two logrotate configs rotate the same log file and logrotate refuses the second (often an old Forge config next to a newer one). Keep one of ¦ Dos archivos de logrotate rotan el mismo log y logrotate rechaza el segundo (a menudo un archivo antiguo de Forge junto a uno nuevo). Deja solo uno de
  Um script postrotate (normalmente o reload de um serviço) falhou depois de rodar os logs — veja se o serviço que ele recarrega está no ar ¦ A postrotate script (usually a service reload) failed after rotating — check that the service it reloads is running ¦ Un script postrotate (normalmente el reload de un servicio) falló después de rotar los logs — comprueba que el servicio que recarga esté en marcha
  O teste de configuração do nginx (nginx -t) falhou; a linha diz qual arquivo e linha. O nginx continua com a configuração antiga até passar ¦ nginx's configuration test (nginx -t) failed; the line says which file and line. nginx keeps the old config until it passes ¦ La prueba de configuración de nginx (nginx -t) falló; la línea indica qué archivo y línea. nginx mantiene la configuración anterior hasta que pase
  Contêiner %@ parou (%@) ¦ Container %@ stopped (%@) ¦ El contenedor %@ se detuvo (%@)
  Contêiner %@ com falha no health check ¦ Container %@ is failing its health check ¦ El contenedor %@ falla su health check
  %@ precisa de atenção ¦ %@ needs attention ¦ %@ necesita atención
  Sem resposta em 30 s ¦ No answer in 30 s ¦ Sin respuesta en 30 s
  Saiu com %@ ¦ Exited with %@ ¦ Salió con %@
  Receitas ¦ Recipes ¦ Recetas
  Comandos de leitura que rodam sob demanda (journal, df, contêineres…) ¦ Read-only commands that run on demand (journal, df, containers…) ¦ Comandos de lectura que se ejecutan a demanda (journal, df, contenedores…)
  Swap ¦ Swap ¦ Swap
  Discos ¦ Disks ¦ Discos
  Sem discos além do /. ¦ No disks besides /. ¦ Sin discos además de /.
  Nenhum contêiner (ou Docker indisponível). ¦ No containers (or Docker unavailable). ¦ Ningún contenedor (o Docker no disponible).
  Receitas · %@ ¦ Recipes · %@ ¦ Recetas · %@
  Fechar ¦ Close ¦ Cerrar
  Rodar ¦ Run ¦ Ejecutar
  Escolha uma receita. ¦ Choose a recipe. ¦ Elige una receta.
  Comando, ex.: tail -n 100 /var/www/app/storage/logs/laravel.log ¦ Command, e.g. tail -n 100 /var/www/app/storage/logs/laravel.log ¦ Comando, p. ej. tail -n 100 /var/www/app/storage/logs/laravel.log
  Rodam pelo seu ssh em BatchMode. As receitas prontas só leem; as suas são comandos seus — prefira comandos de leitura. Agentes podem rodar receitas pelo nome (MCP run_recipe), nunca comandos livres. ¦ They run through your ssh in BatchMode. Built-in recipes only read; yours are your own commands — prefer read-only ones. Agents can run recipes by name (MCP run_recipe), never free-form commands. ¦ Se ejecutan con tu ssh en BatchMode. Las recetas incluidas solo leen; las tuyas son comandos tuyos — prefiere comandos de lectura. Los agentes pueden ejecutar recetas por nombre (MCP run_recipe), nunca comandos libres.
  Notificar quando uma máquina precisar de atenção ¦ Notify when a machine needs attention ¦ Notificar cuando una máquina necesite atención
  24 h ¦ 24 h ¦ 24 h
  Disponibilidade e incidentes ¦ Uptime and incidents ¦ Disponibilidad e incidentes
  incidentes na semana ¦ incidents this week ¦ incidentes en la semana
  Latência nas últimas 24 h ¦ Latency over the last 24 h ¦ Latencia en las últimas 24 h
  Incidentes ¦ Incidents ¦ Incidentes
  Nenhum incidente registrado. ¦ No incidents recorded. ¦ Ningún incidente registrado.
  Guardado em blocos de 5 minutos por 7 dias (contagens e latência, nada mais). ¦ Kept in 5-minute buckets for 7 days (counts and latency, nothing else). ¦ Guardado en bloques de 5 minutos durante 7 días (conteos y latencia, nada más).
  %@ hosts a cada 60 s, só com a página aberta ¦ %@ hosts every 60 s, only while the page is open ¦ %@ hosts cada 60 s, solo con la página abierta
  %@ s ¦ %@ s ¦ %@ s
  %@ verificações a cada 30 s ¦ %@ checks every 30 s ¦ %@ comprobaciones cada 30 s
  1 verificação a cada 30 s ¦ 1 check every 30 s ¦ 1 comprobación cada 30 s
  Acesso do MCP ao app ¦ MCP access to the app ¦ Acceso del MCP a la app
  Agentes, sessões e limites ¦ Agents, sessions and limits ¦ Agentes, sesiones y límites
  Ajudantes (MCP, gancho, status line) ¦ Helpers (MCP, hook, status line) ¦ Ayudantes (MCP, hook, status line)
  App ¦ App ¦ App
  Arquivos .corescope.yml ¦ .corescope.yml files ¦ Archivos .corescope.yml
  Bancos locais ¦ Local databases ¦ Bases de datos locales
  CPU agora ¦ CPU now ¦ CPU ahora
  CPU em % de um núcleo. Cada recurso é medido no tempo de CPU das próprias threads do CoreScope, sem o primeiro minuto (arranque); ajudantes e processos iniciados aparecem à parte. A interface (janela, painel, barra de menus) fica no total do app. ¦ CPU as % of one core. Each feature is measured in CPU time on CoreScope's own threads, leaving out the first minute (startup); helpers and started processes are shown separately. The interface (window, panel, menu bar) is in the app total. ¦ CPU en % de un núcleo. Cada función se mide en tiempo de CPU de los propios hilos de CoreScope, sin el primer minuto (arranque); ayudantes y procesos iniciados aparecen aparte. La interfaz (ventana, panel, barra de menús) está en el total de la app.
  Coletor (processos, portas, sensores) ¦ Collector (processes, ports, sensors) ¦ Recolector (procesos, puertos, sensores)
  CoreScope ¦ CoreScope ¦ CoreScope
  CoreScope %@ · %@ ¦ CoreScope %@ · %@ ¦ CoreScope %@ · %@
  CoreScope está gastando mais do que um monitor deveria. Desligue o que não usa abaixo; os itens medidos como médio ou alto vêm primeiro. ¦ CoreScope is spending more than a monitor should. Turn off what you do not use below; items measured as medium or high come first. ¦ CoreScope está gastando más de lo que un monitor debería. Apaga lo que no uses abajo; los elementos medidos como medio o alto van primero.
  Custo do CoreScope ¦ CoreScope's own cost ¦ Costo de CoreScope
  Limites ao vivo do Codex ¦ Live Codex limits ¦ Límites en vivo de Codex
  via Claude Code %@ ¦ via Claude Code %@ ¦ vía Claude Code %@
  Ler o limite atual pelo Claude Code ¦ Read the current limit through Claude Code ¦ Leer el límite actual con Claude Code
  Pede o limite atual ao próprio Claude Code (atualiza sozinho a cada 5 min enquanto você usa o Claude, a cada 30 min fora disso). ¦ Asks Claude Code itself for the current limit (refreshes on its own every 5 min while you use Claude, every 30 min otherwise). ¦ Pide el límite actual al propio Claude Code (se actualiza solo cada 5 min mientras usas Claude, cada 30 min fuera de eso).
  Roda o /usage do próprio Claude Code, que consulta sua conta com o login dele; não gasta tokens. O CoreScope não lê credenciais. Pode desligar em Ajustes › Agentes. ¦ Runs Claude Code's own /usage, which checks your account with its own login; no tokens are spent. CoreScope reads no credentials. You can turn it off in Settings › Agents. ¦ Ejecuta el /usage del propio Claude Code, que consulta tu cuenta con su propio inicio de sesión; no gasta tokens. CoreScope no lee credenciales. Puedes desactivarlo en Ajustes › Agentes.
  O status line e as amostras do Claude Desktop só se renovam enquanto são usados. Com isto ligado, o CoreScope roda o /usage do próprio Claude Code (a cada 5 min enquanto você usa o Claude, a cada 30 min fora disso) e mostra o mesmo número que o Claude Code e o Claude Desktop; o Claude Code consulta a Anthropic com o login dele, sem gastar tokens. Nenhuma credencial é lida pelo CoreScope. ¦ The status line and Claude Desktop's samples only refresh while they are in use. With this on, CoreScope runs Claude Code's own /usage (every 5 min while you use Claude, every 30 min otherwise) and shows the same number as Claude Code and Claude Desktop; Claude Code asks Anthropic with its own login, without spending tokens. CoreScope reads no credentials. ¦ El status line y las muestras de Claude Desktop solo se renuevan mientras se usan. Con esto activado, CoreScope ejecuta el /usage del propio Claude Code (cada 5 min mientras usas Claude, cada 30 min fuera de eso) y muestra el mismo número que Claude Code y Claude Desktop; Claude Code consulta a Anthropic con su propio inicio de sesión, sin gastar tokens. CoreScope no lee credenciales.
  Limites ao vivo do Claude ¦ Live Claude limits ¦ Límites en vivo de Claude
  roda claude -p /usage a cada 5 min com o Claude em uso, 30 min sem · alguns segundos de CPU por leitura ¦ runs claude -p /usage every 5 min while Claude is in use, 30 min otherwise · a few seconds of CPU per read ¦ ejecuta claude -p /usage cada 5 min con Claude en uso, 30 min sin él · unos segundos de CPU por lectura
  Modo economia ¦ Economy mode ¦ Modo ahorro
  Máquinas (ssh) ¦ Machines (ssh) ¦ Máquinas (ssh)
  Média 5 min ¦ 5-min average ¦ Media 5 min
  Portas e exposição ¦ Ports and exposure ¦ Puertos y exposición
  Processos iniciados pelo app ¦ Processes the app started ¦ Procesos iniciados por la app
  Quanto o próprio CoreScope está gastando ¦ What CoreScope itself is spending ¦ Cuánto está gastando el propio CoreScope
  Status line do Claude ¦ Claude status line ¦ Status line de Claude
  a cada %@ s com janela ou painel visível, 10 s sem · %@ ms por passagem ¦ every %@ s with the window or panel visible, 10 s otherwise · %@ ms per pass ¦ cada %@ s con ventana o panel visible, 10 s sin ellos · %@ ms por pasada
  a cada 15 s, só com a página aberta ¦ every 15 s, only while the page is open ¦ cada 15 s, solo con la página abierta
  a cada 2 s, só com a página aberta ¦ every 2 s, only while the page is open ¦ cada 2 s, solo con la página abierta
  a cada 20 s ¦ every 20 s ¦ cada 20 s
  a cada 20 s, só arquivos novos ou alterados ¦ every 20 s, only new or changed files ¦ cada 20 s, solo archivos nuevos o cambiados
  inicia o codex app-server a cada 5 min ¦ starts codex app-server every 5 min ¦ inicia codex app-server cada 5 min
  mantém o coletor no intervalo rápido mesmo com a janela fechada ¦ keeps the collector at the fast interval even with the window closed ¦ mantiene el recolector en el intervalo rápido incluso con la ventana cerrada
  relê a cada 60 s; procura pastas novas a cada 10 min ¦ re-reads every 60 s; looks for new folders every 10 min ¦ relee cada 60 s; busca carpetas nuevas cada 10 min
  roda o corescope a cada atualização do status line do Claude ¦ runs corescope on every Claude status line update ¦ ejecuta corescope en cada actualización del status line de Claude
  socket local parado até um agente pedir algo ¦ local socket, idle until an agent asks ¦ socket local, inactivo hasta que un agente pida algo
  só enquanto uma tela com contêineres está aberta ¦ only while a screen showing containers is open ¦ solo mientras una pantalla con contenedores está abierta
  só na bateria, a cada coleta ¦ on battery only, every sample ¦ solo con batería, en cada muestra
  só quando você pede um escaneamento ¦ only when you ask for a scan ¦ solo cuando pides un escaneo
  uma gravação por minuto, dentro do coletor; consultas da página à parte ¦ one write per minute, inside the collector; page queries separately ¦ una escritura por minuto, dentro del recolector; consultas de la página aparte
  %@ minutos registrados entre %@ e %@. ¦ %@ minutes recorded between %@ and %@. ¦ %@ minutos registrados entre %@ y %@.
  Abrir %@ ¦ Open %@ ¦ Abrir %@
  Abrir Serviços ¦ Open Services ¦ Abrir Servicios
  Abrir projeto %@ ¦ Open project %@ ¦ Abrir proyecto %@
  CPU média de %@ (pico de %@ às %@). ¦ CPU averaged %@ (peak %@ at %@). ¦ CPU media de %@ (pico de %@ a las %@).
  Escolha um momento para ver CPU, energia, memória e quem dominou nos 10 minutos em volta, comparados com a hora anterior. Também pelo ⌥⌘K, por corescope://happened?at=14:05 e pelo MCP (what_happened). ¦ Pick a moment to see CPU, power, memory and who dominated in the 10 minutes around it, against the hour before. Also from ⌥⌘K, corescope://happened?at=14:05 and MCP (what_happened). ¦ Elige un momento para ver CPU, energía, memoria y quién dominó en los 10 minutos alrededor, comparados con la hora anterior. También con ⌥⌘K, corescope://happened?at=14:05 y el MCP (what_happened).
  Estado térmico chegou a crítico. ¦ Thermal state reached critical. ¦ El estado térmico llegó a crítico.
  Estado térmico chegou a sério (com redução de desempenho). ¦ Thermal state reached serious (throttling). ¦ El estado térmico llegó a serio (con reducción de rendimiento).
  Gravação em disco chegou a %@. ¦ Disk writes peaked at %@. ¦ La escritura en disco llegó a %@.
  Iniciar o perfil %@? ¦ Start the %@ profile? ¦ ¿Iniciar el perfil %@?
  Iniciar perfil %@ ¦ Start profile %@ ¦ Iniciar perfil %@
  Maior energia ¦ Most power ¦ Mayor energía
  Na hora anterior: %@. ¦ The hour before: %@. ¦ La hora anterior: %@.
  Nada encontrado ¦ Nothing found ¦ Nada encontrado
  Nada registrado entre %@ e %@: Mac em repouso, CoreScope fechado ou histórico desligado. ¦ Nothing recorded between %@ and %@: the Mac was asleep, CoreScope was closed or history was off. ¦ Nada registrado entre %@ y %@: Mac en reposo, CoreScope cerrado o historial apagado.
  Nenhum perfil chamado %@. ¦ No profile named %@. ¦ Ningún perfil llamado %@.
  O que aconteceu às %@ ¦ What happened at %@ ¦ Qué pasó a las %@
  O que aconteceu às… ¦ What happened at… ¦ Qué pasó a las…
  Parar perfil %@ ¦ Stop profile %@ ¦ Detener perfil %@
  Pedido por um link corescope://. Os comandos vêm de %@: ¦ Asked by a corescope:// link. The commands come from %@: ¦ Pedido por un enlace corescope://. Los comandos vienen de %@:
  Porta ou ação ¦ Port or action ¦ Puerto o acción
  Pressão de memória chegou a atenção. ¦ Memory pressure reached warning. ¦ La presión de memoria llegó a advertencia.
  Pressão de memória chegou a crítica. ¦ Memory pressure reached critical. ¦ La presión de memoria llegó a crítica.
  Swap cresceu %@ (para %@). ¦ Swap grew %@ (to %@). ¦ El swap creció %@ (hasta %@).
  Ver ¦ Show ¦ Ver
  Verificar %@ ¦ Check %@ ¦ Comprobar %@
  Verificar serviços ¦ Check services ¦ Comprobar servicios
  ainda não verificado ¦ not checked yet ¦ aún no comprobado
  Energia dos processos: média de %@ (pico de %@ às %@). ¦ Process power averaged %@ (peak %@ at %@). ¦ Energía de los procesos: media de %@ (pico de %@ a las %@).
  Horário não reconhecido: use 14:05, 2:05 pm ou ontem 9:30 ¦ Time not recognized: use 14:05, 2:05 pm or yesterday 9:30 ¦ Hora no reconocida: usa 14:05, 2:05 pm o ayer 9:30
  Ainda não medido. A primeira medição roda 3 minutos depois de abrir o app, ou agora pelo botão. ¦ Not measured yet. The first measurement runs 3 minutes after the app opens, or now with the button. ¦ Aún sin medir. La primera medición se hace 3 minutos después de abrir la app, o ahora con el botón.
  Crescimento do disco ¦ Disk growth ¦ Crecimiento del disco
  Espaço livre ¦ Free space ¦ Espacio libre
  Medido em %@, comparado com %@. ¦ Measured %@, compared with %@. ¦ Medido el %@, comparado con %@.
  Medir agora ¦ Measure now ¦ Medir ahora
  O que cresceu hoje ¦ What grew today ¦ Qué creció hoy
  Pastas que costumam encher o disco de quem desenvolve: caches, Xcode e simuladores, VMs de contêiner, lojas de pacotes, modelos, Downloads, Lixeira e dados de agentes. Medidas no máximo a cada 6 h em segundo plano (alguns segundos de disco); limpar continua com você, na Limpeza. Também: corescope disk-growth e MCP disk_growth. ¦ Folders that usually fill a developer's disk: caches, Xcode and simulators, container VMs, package stores, models, Downloads, Trash and agent data. Measured at most every 6 h in the background (a few seconds of disk); cleaning stays with you, in Cleanup. Also: corescope disk-growth and MCP disk_growth. ¦ Carpetas que suelen llenar el disco de quien desarrolla: cachés, Xcode y simuladores, VMs de contenedores, almacenes de paquetes, modelos, Descargas, Papelera y datos de agentes. Medidas como máximo cada 6 h en segundo plano (unos segundos de disco); limpiar sigue en tus manos, en Limpieza. También: corescope disk-growth y MCP disk_growth.
  Primeira medição em %@: o crescimento aparece a partir da próxima. ¦ First measurement %@: growth shows from the next one. ¦ Primera medición el %@: el crecimiento aparece desde la próxima.
  mede no máximo a cada 6 h, alguns segundos de disco ¦ measures at most every 6 h, a few seconds of disk ¦ mide como máximo cada 6 h, unos segundos de disco
  Versão %@ (build %@) ¦ Version %@ (build %@) ¦ Versión %@ (build %@)
  AGENTES ¦ AGENTS ¦ AGENTES
  MÁQUINAS ¦ MACHINES ¦ MÁQUINAS
  Nenhum agente em execução ¦ No agents running ¦ Ningún agente en ejecución
  + %@ na página Agentes ¦ + %@ on the Agents page ¦ + %@ en la página Agentes
  Escolha as máquinas em Ajustes › Painel flutuante ¦ Choose machines in Settings › Floating panel ¦ Elige las máquinas en Ajustes › Panel flotante
  sem conexão ¦ unreachable ¦ sin conexión
  Memória %@ de %@ ¦ Memory %@ of %@ ¦ Memoria %@ de %@
  Disco / %@ de %@ ¦ Disk / %@ of %@ ¦ Disco / %@ de %@
  Ativa ¦ Running ¦ Activa
  Aguardando sua próxima mensagem ¦ Waiting for your next message ¦ Esperando tu próximo mensaje
  Em execução (o agente não informa o estado) ¦ Running (this agent does not report its state) ¦ En ejecución (el agente no informa su estado)
  Mostrar agentes ¦ Show agents ¦ Mostrar agentes
  Mostrar máquinas remotas ¦ Show remote machines ¦ Mostrar máquinas remotas
  Sessões do Claude Code, Codex e outros agentes: projeto, se está trabalhando, aguardando ou parece travada, e os limites de uso. ¦ Claude Code, Codex and other agent sessions: project, whether each is working, waiting or looks stuck, and the usage limits. ¦ Sesiones de Claude Code, Codex y otros agentes: proyecto, si trabaja, espera o parece atascada, y los límites de uso.
  Nenhuma máquina ainda. ¦ No machines yet. ¦ Aún no hay máquinas.
  Abrir Máquinas ¦ Open Machines ¦ Abrir Máquinas
  As máquinas marcadas são lidas pelo ssh a cada 60 s enquanto o painel está visível, no mesmo ritmo da página Máquinas (as duas abertas não leem mais vezes). ¦ Checked machines are read over ssh every 60 s while the panel is visible, on the same schedule as the Machines page (both open never read more often). ¦ Las máquinas marcadas se leen por ssh cada 60 s mientras el panel está visible, al mismo ritmo que la página Máquinas (las dos abiertas no leen más veces).
  Mostrar no painel flutuante ¦ Show in the floating panel ¦ Mostrar en el panel flotante
  %@ hosts a cada 60 s com a página aberta; %@ sempre, pelo painel flutuante ¦ %@ hosts every 60 s with the page open; %@ always, for the floating panel ¦ %@ hosts cada 60 s con la página abierta; %@ siempre, por el panel flotante
  Atualizações ¦ Updates ¦ Actualizaciones
  Procurar atualizações (uma vez por dia) ¦ Check for updates (once a day) ¦ Buscar actualizaciones (una vez al día)
  Procurar atualizações ¦ Update check ¦ Búsqueda de actualizaciones
  um pedido ao GitHub por dia, no máximo ¦ one request to GitHub a day at most ¦ una solicitud a GitHub al día como máximo
  Versão instalada ¦ Installed version ¦ Versión instalada
  Procurar agora ¦ Check now ¦ Buscar ahora
  Você está na versão mais recente · verificado %@ ¦ You're on the latest version · checked %@ ¦ Tienes la versión más reciente · comprobado %@
  Última verificação %@ ¦ Last checked %@ ¦ Última comprobación %@
  CoreScope %@ disponível ¦ CoreScope %@ available ¦ CoreScope %@ disponible
  Baixando… ¦ Downloading… ¦ Descargando…
  Instalando e reabrindo… ¦ Installing and relaunching… ¦ Instalando y reabriendo…
  Instalar e reabrir ¦ Install and relaunch ¦ Instalar y reabrir
  Ver no GitHub ¦ View on GitHub ¦ Ver en GitHub
  Veja as novidades e instale em Ajustes › Atualizações. ¦ See what's new and install it in Settings › Updates. ¦ Mira las novedades e instálala en Ajustes › Actualizaciones.
  Esta cópia não tem a chave de atualização (build local). ¦ This copy has no update key (local build). ¦ Esta copia no tiene la clave de actualización (build local).
  Desligado por padrão. Ligado, o CoreScope busca no máximo uma vez por dia o appcast da última versão no GitHub (github.com e o servidor de downloads do GitHub), sem identificadores nem dados do Mac. Só instala quando você clica em Instalar e reabrir, e só uma atualização assinada com a chave do projeto (EdDSA). Também: corescope version --check. ¦ Off by default. When on, CoreScope fetches the latest release's appcast from GitHub at most once a day (github.com and GitHub's download server), with no identifiers or data about this Mac. It installs only when you click Install and relaunch, and only an update signed with the project's key (EdDSA). Also: corescope version --check. ¦ Desactivado por defecto. Activado, CoreScope descarga como máximo una vez al día el appcast de la última versión en GitHub (github.com y el servidor de descargas de GitHub), sin identificadores ni datos del Mac. Solo instala cuando haces clic en Instalar y reabrir, y solo una actualización firmada con la clave del proyecto (EdDSA). También: corescope version --check.
  Desempenho ¦ Performance ¦ Rendimiento
  Eficiência ¦ Efficiency ¦ Eficiencia
  desempenho ¦ performance ¦ rendimiento
  eficiência ¦ efficiency ¦ eficiencia
  Rápidos: builds, testes e o app em uso ¦ Fast: builds, tests and the app you're using ¦ Rápidos: builds, pruebas y la app en uso
  Econômicos: tarefas leves e em segundo plano ¦ Economical: light and background tasks ¦ Económicos: tareas ligeras y en segundo plano
  Núcleo %@: %@ ¦ Core %@: %@ ¦ Núcleo %@: %@
  Cada quadrado é um núcleo; mais cheio, mais ocupado. ¦ Each tile is a core; the fuller, the busier. ¦ Cada cuadro es un núcleo; cuanto más lleno, más ocupado.
  folga ¦ calm ¦ holgado
  ocupado ¦ busy ¦ ocupado
  no limite ¦ at the limit ¦ al límite
  %@ arquivos abertos ¦ %@ open files ¦ %@ archivos abiertos
  %@ arquivos verificados em %@ s, %@. ¦ %@ files checked in %@ s, %@. ¦ %@ archivos revisados en %@ s, %@.
  %@ ciclos ¦ %@ power cycles ¦ %@ ciclos
  %@ da vida útil usada ¦ %@ of rated life used ¦ %@ de la vida útil usada
  %@ desligamentos inesperados ¦ %@ unsafe shutdowns ¦ %@ apagados inesperados
  %@ erros de mídia ¦ %@ media errors ¦ %@ errores de medio
  %@ escritos ¦ %@ written ¦ %@ escritos
  %@ h ligado ¦ %@ h powered on ¦ %@ h encendido
  %@ liberados. ¦ %@ freed. ¦ %@ liberados.
  %@ lidos ¦ %@ read ¦ %@ leídos
  %@ na Lixeira. ¦ %@ in the Trash. ¦ %@ en la Papelera.
  %@ processos usam este volume: ¦ %@ processes are using this volume: ¦ %@ procesos usan este volumen:
  %@/h em média ¦ %@/h on average ¦ %@/h de media
  Arquivos grandes ¦ Large files ¦ Archivos grandes
  Bytes lidos e escritos por processo desde a última amostra (rusage). Também: corescope top --disk e MCP top_processes by: disk. ¦ Bytes read and written per process since the last sample (rusage). Also: corescope top --disk and MCP top_processes by: disk. ¦ Bytes leídos y escritos por proceso desde la última muestra (rusage). También: corescope top --disk y MCP top_processes by: disk.
  Concluído. %@ ¦ Done. %@ ¦ Listo. %@
  Ejetado. Já pode desconectar. ¦ Ejected. You can disconnect it now. ¦ Expulsado. Ya puedes desconectarlo.
  Ejetar ¦ Eject ¦ Expulsar
  Ejetar %@ ¦ Eject %@ ¦ Expulsar %@
  Ejetar… ¦ Eject… ¦ Expulsar…
  Executar ¦ Run ¦ Ejecutar
  Executar %@ (%@) ¦ Run %@ (%@) ¦ Ejecutar %@ (%@)
  Executar %@ ações? ¦ Run %@ actions? ¦ ¿Ejecutar %@ acciones?
  Falhou (código %@): %@ ¦ Failed (code %@): %@ ¦ Falló (código %@): %@
  Falhou ao ejetar. ¦ Failed to eject. ¦ No se pudo expulsar.
  Gerenciado por %@: remova pelo próprio app. ¦ Managed by %@: remove it from that app. ¦ Gestionado por %@: elimínalo desde esa app.
  Já em execução. ¦ Already running. ¦ Ya en ejecución.
  Liberar %@ ¦ Free %@ ¦ Liberar %@
  Liberar espaço com segurança ¦ Free up space safely ¦ Liberar espacio con seguridad
  Marca "%@" no plano de limpeza abaixo. ¦ Checks "%@" in the cleanup plan below. ¦ Marca "%@" en el plan de limpieza de abajo.
  Mostra o que usa o volume antes de ejetar ¦ Shows what is using the volume before ejecting ¦ Muestra qué usa el volumen antes de expulsar
  Mover %@ para a Lixeira ¦ Move %@ to the Trash ¦ Mover %@ a la Papelera
  Mover para a Lixeira ¦ Move to the Trash ¦ Mover a la Papelera
  Mover para a Lixeira? ¦ Move to the Trash? ¦ ¿Mover a la Papelera?
  Nada a liberar agora. ¦ Nothing to free now. ¦ Nada que liberar ahora.
  Nada a liberar nos caches conhecidos. ¦ Nothing to free in the known caches. ¦ Nada que liberar en las cachés conocidas.
  Nenhum arquivo acima do tamanho escolhido. ¦ No file above the chosen size. ¦ Ningún archivo por encima del tamaño elegido.
  Nenhum processo lendo ou escrevendo mais de 64 KB/s. ¦ No process reading or writing more than 64 KB/s. ¦ Ningún proceso leyendo o escribiendo más de 64 KB/s.
  Nenhum processo seu usa este volume. ¦ None of your processes is using this volume. ¦ Ningún proceso tuyo usa este volumen.
  Não executado: %@ está em uso. ¦ Not run: %@ is in use. ¦ No ejecutado: %@ está en uso.
  Núcleo %@ (%@): %@ ¦ Core %@ (%@): %@ ¦ Núcleo %@ (%@): %@
  Parou no limite de tempo: pode faltar algum. ¦ Stopped at the time limit: some may be missing. ¦ Se detuvo en el límite de tiempo: puede faltar alguno.
  Pastas vão para a Lixeira (recuperáveis); comandos rodam no seu shell com o caminho completo da ferramenta; dados do Docker são removidos pelo motor (sem volta). Uma ação cuja ferramenta está rodando não é executada. Também: corescope space --plan e MCP cleanup_plan / run_cleanup_plan. ¦ Folders go to the Trash (recoverable); commands run in your shell with the tool's full path; Docker data is removed by the engine (permanent). An action whose tool is running is not run. Also: corescope space --plan and MCP cleanup_plan / run_cleanup_plan. ¦ Las carpetas van a la Papelera (recuperables); los comandos se ejecutan en tu shell con la ruta completa de la herramienta; los datos de Docker los elimina el motor (sin vuelta atrás). No se ejecuta una acción cuya herramienta está en uso. También: corescope space --plan y MCP cleanup_plan / run_cleanup_plan.
  Procura na sua pasta pessoal (e nas pastas que ela aponta para outros discos) os maiores arquivos: imagens de disco, vídeos, VMs, dumps e modelos. Fica fora: nuvem (OneDrive, iCloud), node_modules, .git e outros volumes montados. ¦ Searches your home folder (and folders it points to on other drives) for the largest files: disk images, videos, VMs, dumps and models. Left out: cloud storage (OneDrive, iCloud), node_modules, .git and other mounted volumes. ¦ Busca en tu carpeta personal (y en las carpetas que apuntan a otros discos) los archivos más grandes: imágenes de disco, vídeos, VMs, dumps y modelos. Quedan fuera: la nube (OneDrive, iCloud), node_modules, .git y otros volúmenes montados.
  Procurando o que usa o volume… ¦ Looking for what is using the volume… ¦ Buscando qué usa el volumen…
  Procurar ¦ Search ¦ Buscar
  Procurar de novo ¦ Search again ¦ Buscar de nuevo
  Pré-visualizar (Quick Look) ¦ Preview (Quick Look) ¦ Previsualizar (Quick Look)
  Página SMART/Health do NVMe: percentual da resistência nominal usado, blocos de reserva, dados escritos e lidos (unidades de 512 000 bytes), ciclos, horas ligado, desligamentos inesperados e erros de mídia. ¦ NVMe SMART/Health page: share of rated endurance used, spare blocks, data written and read (512,000-byte units), power cycles, power-on hours, unsafe shutdowns and media errors. ¦ Página SMART/Health del NVMe: porcentaje de la resistencia nominal usado, bloques de reserva, datos escritos y leídos (unidades de 512 000 bytes), ciclos, horas encendido, apagados inesperados y errores de medio.
  Saúde do SSD (SMART) ¦ SSD health (SMART) ¦ Salud del SSD (SMART)
  Sem dados de saúde (SMART NVMe %@). ¦ No health data (NVMe SMART %@). ¦ Sin datos de salud (SMART NVMe %@).
  Serviços do sistema (como o Spotlight) também podem segurar um volume; o macOS diz quais se a ejeção falhar. ¦ System services (like Spotlight) can also hold a volume; macOS names them if the eject fails. ¦ Los servicios del sistema (como Spotlight) también pueden retener un volumen; macOS dice cuáles si la expulsión falla.
  Subpastas que mais cresceram ¦ Subfolders that grew the most ¦ Subcarpetas que más crecieron
  Também: corescope large-files e MCP large_files. Arquivos de apps (Docker, OrbStack, Claude, Photos, Hugging Face…) só aparecem: remova pelo próprio app. ¦ Also: corescope large-files and MCP large_files. Files owned by apps (Docker, OrbStack, Claude, Photos, Hugging Face…) are only shown: remove them from that app. ¦ También: corescope large-files y MCP large_files. Los archivos de apps (Docker, OrbStack, Claude, Photos, Hugging Face…) solo se muestran: elimínalos desde esa app.
  Tempo esgotado (10 min). ¦ Timed out (10 min). ¦ Tiempo agotado (10 min).
  Tentar ejetar mesmo assim ¦ Try to eject anyway ¦ Intentar expulsar de todos modos
  Usando o disco agora ¦ Using the disk now ¦ Usando el disco ahora
  Ver no Histórico ¦ See in History ¦ Ver en el Historial
  arquivo aberto ¦ open file ¦ archivo abierto
  atenção ¦ watch ¦ atención
  em uso: %@ ¦ in use: %@ ¦ en uso: %@
  lê ao abrir Armazenamento, no máximo a cada 10 min ¦ reads when Storage opens, at most every 10 min ¦ lee al abrir Almacenamiento, como máximo cada 10 min
  pasta de trabalho no volume ¦ working folder on the volume ¦ carpeta de trabajo en el volumen
  permanente ¦ permanent ¦ permanente
  reserva %@ (mín. %@) ¦ spare %@ (min. %@) ¦ reserva %@ (mín. %@)
  roda a partir do volume ¦ runs from the volume ¦ se ejecuta desde el volumen
  saudável ¦ healthy ¦ saludable
  trocar ¦ replace ¦ reemplazar
  não exposto por este disco ou adaptador ¦ not exposed by this disk or adapter ¦ no expuesto por este disco o adaptador
  %@ chaves; %@ amostradas (SCAN), memória por chave com MEMORY USAGE. ¦ %@ keys; %@ sampled (SCAN), memory per key with MEMORY USAGE. ¦ %@ claves; %@ muestreadas (SCAN), memoria por clave con MEMORY USAGE.
  %@ voltou ao snapshot de %@. ¦ %@ is back to the snapshot from %@. ¦ %@ volvió al snapshot de %@.
  %@%% sem TTL ¦ %@%% without TTL ¦ %@%% sin TTL
  Abrir em um app de banco (TablePlus, Redis Insight…) ou copiar a URL de conexão, sem senha ¦ Open in a database app (TablePlus, Redis Insight…) or copy the connection URL, without a password ¦ Abrir en una app de bases de datos (TablePlus, Redis Insight…) o copiar la URL de conexión, sin contraseña
  Abrir no %@ ¦ Open in %@ ¦ Abrir en %@
  Amostrando chaves… ¦ Sampling keys… ¦ Muestreando claves…
  Antes de um migrate:fresh ou db:wipe, tire um snapshot; restaurar volta o banco exatamente àquele ponto. O dump roda dentro do contêiner com as credenciais dele; agentes usam db_snapshot pelo MCP. ¦ Before a migrate:fresh or db:wipe, take a snapshot; restoring puts the database back exactly to that point. The dump runs inside the container with its own credentials; agents use db_snapshot over MCP. ¦ Antes de un migrate:fresh o db:wipe, haz un snapshot; restaurar devuelve la base exactamente a ese punto. El dump corre dentro del contenedor con sus propias credenciales; los agentes usan db_snapshot por MCP.
  Apagando… ¦ Deleting… ¦ Borrando…
  Apagar este snapshot? ¦ Delete this snapshot? ¦ ¿Borrar este snapshot?
  Apagar snapshot ¦ Delete snapshot ¦ Borrar snapshot
  Apagar todas as chaves ¦ Delete every key ¦ Borrar todas las claves
  Chaves por prefixo, memória e chaves sem TTL (amostra) ¦ Keys by prefix, memory and keys without TTL (sampled) ¦ Claves por prefijo, memoria y claves sin TTL (muestra)
  Chaves que nunca expiram crescem até alguém apagar. ¦ Keys that never expire grow until someone deletes them. ¦ Las claves que nunca expiran crecen hasta que alguien las borra.
  Copiar DSN ¦ Copy DSN ¦ Copiar DSN
  Esvaziar db%@ do Redis :%@? ¦ Empty db%@ of Redis :%@? ¦ ¿Vaciar db%@ de Redis :%@?
  Esvaziar db%@… ¦ Empty db%@… ¦ Vaciar db%@…
  FLUSHDB apaga as %@ chaves deste banco, sem volta. Use só em dados de desenvolvimento. ¦ FLUSHDB deletes this database's %@ keys, permanently. Use it only on development data. ¦ FLUSHDB borra las %@ claves de esta base, sin vuelta atrás. Úsalo solo con datos de desarrollo.
  Falhou: %@ ¦ Failed: %@ ¦ Falló: %@
  Fazendo snapshot de %@… ¦ Taking a snapshot of %@… ¦ Haciendo snapshot de %@…
  Fazer snapshot ¦ Take snapshot ¦ Hacer snapshot
  Novo snapshot… ¦ New snapshot… ¦ Nuevo snapshot…
  O banco %@ é apagado e recriado como estava em %@. O que mudou depois se perde. ¦ Database %@ is dropped and recreated as it was on %@. Anything changed since is lost. ¦ La base %@ se borra y se recrea como estaba el %@. Lo que cambió después se pierde.
  Para um banco fora de contêiner, o snapshot só funciona com acesso local sem senha. ¦ For a database outside a container, snapshots need passwordless local access. ¦ Para una base fuera de un contenedor, el snapshot solo funciona con acceso local sin contraseña.
  Redis :%@ · db%@ ¦ Redis :%@ · db%@ ¦ Redis :%@ · db%@
  Restaurando %@… ¦ Restoring %@… ¦ Restaurando %@…
  Restaurar ¦ Restore ¦ Restaurar
  Restaurar %@? ¦ Restore %@? ¦ ¿Restaurar %@?
  Restaurar… ¦ Restore… ¦ Restaurar…
  Snapshot apagado. ¦ Snapshot deleted. ¦ Snapshot borrado.
  Snapshot de %@ salvo. ¦ Snapshot of %@ saved. ¦ Snapshot de %@ guardado.
  Snapshots ¦ Snapshots ¦ Snapshots
  db%@ esvaziado. ¦ db%@ emptied. ¦ db%@ vaciada.
  ~%@ chaves ¦ ~%@ keys ¦ ~%@ claves
  no ritmo atual, chega a 100%% às %@ ¦ at this pace, hits 100%% at %@ ¦ a este ritmo, llega al 100%% a las %@
  no ritmo atual, ~%@ no reinício ¦ at this pace, ~%@ at the reset ¦ a este ritmo, ~%@ al reiniciar
  via Claude Desktop %@ · sem horário de reinício; atualiza enquanto o Claude Desktop está aberto ¦ via Claude Desktop %@ · no reset time; updates while Claude Desktop is open ¦ vía Claude Desktop %@ · sin hora de reinicio; se actualiza mientras Claude Desktop está abierto
  Lido de ~/Library/Application Support/Claude/plan-usage-history.json, que o Claude Desktop grava a cada poucos minutos. Ative o status line em Ajustes › Agentes para ter o horário de reinício e o ritmo. ¦ Read from ~/Library/Application Support/Claude/plan-usage-history.json, which Claude Desktop writes every few minutes. Turn on the status line in Settings › Agents for the reset time and pace. ¦ Leído de ~/Library/Application Support/Claude/plan-usage-history.json, que Claude Desktop escribe cada pocos minutos. Activa el status line en Ajustes › Agentes para tener la hora de reinicio y el ritmo.
  Restaurar suas configurações? ¦ Restore your settings? ¦ ¿Restaurar tu configuración?
  O CoreScope abriu sem configurações, mas há um backup de %@ em %@ (perfis, Serviços, máquinas e preferências). ¦ CoreScope opened without settings, but there is a backup from %@ in %@ (profiles, Services, machines and preferences). ¦ CoreScope se abrió sin configuración, pero hay una copia de %@ en %@ (perfiles, Servicios, máquinas y preferencias).
  Começar do zero ¦ Start from scratch ¦ Empezar de cero
  Backup ilegível: %@ ¦ Unreadable backup: %@ ¦ Copia ilegible: %@
  Backup das configurações ¦ Settings backup ¦ Copia de la configuración
  Manter um backup das configurações ¦ Keep a backup of the settings ¦ Mantener una copia de la configuración
  Alterar… ¦ Change… ¦ Cambiar…
  Último backup ¦ Last backup ¦ Última copia
  ainda não ¦ not yet ¦ todavía no
  Fazer backup agora ¦ Back up now ¦ Hacer copia ahora
  Backup salvo. ¦ Backup saved. ¦ Copia guardada.
  Atualizar o app mantém as configurações. Desinstaladores (AppCleaner, CleanMyMac, brew uninstall --zap) apagam ~/Library/Preferences e Application Support; com o backup numa pasta fora de ~/Library, o CoreScope oferece restaurar ao abrir sem configurações. Guarda perfis, Serviços, máquinas, receitas, pastas de projeto e preferências; não guarda o histórico nem os snapshots de banco. Escolha uma pasta no iCloud Drive para levar para outro Mac. ¦ Updating the app keeps the settings. Uninstallers (AppCleaner, CleanMyMac, brew uninstall --zap) delete ~/Library/Preferences and Application Support; with the backup in a folder outside ~/Library, CoreScope offers to restore it when it opens without settings. It keeps profiles, Services, machines, recipes, project folders and preferences; not the history or database snapshots. Pick a folder in iCloud Drive to take them to another Mac. ¦ Actualizar la app mantiene la configuración. Los desinstaladores (AppCleaner, CleanMyMac, brew uninstall --zap) borran ~/Library/Preferences y Application Support; con la copia en una carpeta fuera de ~/Library, CoreScope ofrece restaurarla al abrirse sin configuración. Guarda perfiles, Servicios, máquinas, recetas, carpetas de proyecto y preferencias; no el historial ni los snapshots de bases. Elige una carpeta en iCloud Drive para llevarla a otro Mac.
  Usar esta pasta ¦ Use this folder ¦ Usar esta carpeta
  Restaurar este backup? ¦ Restore this backup? ¦ ¿Restaurar esta copia?
  As configurações atuais são substituídas pelas do backup e o CoreScope reinicia. ¦ The current settings are replaced by the backup's and CoreScope restarts. ¦ La configuración actual se reemplaza por la de la copia y CoreScope se reinicia.
  Restaurar e reiniciar ¦ Restore and restart ¦ Restaurar y reiniciar
  alguns segundos depois de uma mudança, só se mudou algo ¦ a few seconds after a change, only if something changed ¦ unos segundos después de un cambio, solo si cambió algo
  %@ logs ¦ %@ logs ¦ %@ logs
  %@ serviços ¦ %@ services ¦ %@ servicios
  .corescope.yml válido, só com o nome ¦ Valid .corescope.yml, name only ¦ .corescope.yml válido, solo con el nombre
  .corescope.yml, linha %@ ¦ .corescope.yml, line %@ ¦ .corescope.yml, línea %@
  Abrir ¦ Open ¦ Abrir
  Adicionar projeto ¦ Add project ¦ Añadir proyecto
  Adicionar projeto… ¦ Add project… ¦ Añadir proyecto…
  Criar .corescope.yml e adicionar ¦ Create .corescope.yml and add ¦ Crear .corescope.yml y añadir
  Criar .corescope.yml? ¦ Create .corescope.yml? ¦ ¿Crear .corescope.yml?
  Criar e adicionar ¦ Create and add ¦ Crear y añadir
  Dentro do repositório %@ ¦ Inside the repository %@ ¦ Dentro del repositorio %@
  Escolha a pasta do projeto (a raiz do repositório ou uma subpasta). ¦ Choose the project folder (the repository root or a subfolder). ¦ Elige la carpeta del proyecto (la raíz del repositorio o una subcarpeta).
  Escolher pasta ¦ Choose folder ¦ Elegir carpeta
  Esta pasta já está na lista. ¦ This folder is already in the list. ¦ Esta carpeta ya está en la lista.
  Esta pasta não tem .corescope.yml. O CoreScope cria um modelo mínimo (só o nome) com o mesmo gravador do resto do app; sem ele o projeto não é adicionado. ¦ This folder has no .corescope.yml. CoreScope creates a minimal one (just the name) with the same writer the rest of the app uses; without it the project is not added. ¦ Esta carpeta no tiene .corescope.yml. CoreScope crea uno mínimo (solo el nombre) con el mismo escritor que el resto de la app; sin él el proyecto no se añade.
  HEAD destacado em %@ ¦ Detached HEAD at %@ ¦ HEAD separado en %@
  Inicializar repositório ¦ Initialize repository ¦ Inicializar repositorio
  Inicializar repositório… ¦ Initialize repository… ¦ Inicializar repositorio…
  Inicializar um repositório git aqui? ¦ Initialize a git repository here? ¦ ¿Inicializar un repositorio git aquí?
  Nenhum projeto ainda. Adicione a pasta de um repositório: o CoreScope lê o .corescope.yml (ou oferece criar um) e o git dela, sem abrir uma IDE. ¦ No projects yet. Add a repository folder: CoreScope reads its .corescope.yml (or offers to create one) and its git, without opening an IDE. ¦ Aún no hay proyectos. Añade la carpeta de un repositorio: CoreScope lee su .corescope.yml (u ofrece crear uno) y su git, sin abrir un IDE.
  Não adicionar ¦ Don't add ¦ No añadir
  Remover %@ da lista? ¦ Remove %@ from the list? ¦ ¿Quitar %@ de la lista?
  Remover da lista… ¦ Remove from list… ¦ Quitar de la lista…
  Renomear ¦ Rename ¦ Renombrar
  Repositórios locais que você acompanha: a configuração do .corescope.yml e o estado do git. ¦ Local repositories you follow: their .corescope.yml configuration and git state. ¦ Repositorios locales que sigues: la configuración de .corescope.yml y el estado de git.
  Roda git init em %@. Nada é commitado. ¦ Runs git init in %@. Nothing is committed. ¦ Ejecuta git init en %@. No se hace ningún commit.
  Sem repositório git ¦ No git repository ¦ Sin repositorio git
  Só sai do CoreScope: a pasta, o .corescope.yml e o repositório ficam como estão. ¦ It only leaves CoreScope: the folder, the .corescope.yml and the repository stay as they are. ¦ Solo sale de CoreScope: la carpeta, el .corescope.yml y el repositorio quedan como están.
  Um arquivo mínimo com o nome do projeto. Se você recusar, o projeto não é adicionado. ¦ A minimal file with the project's name. If you decline, the project is not added. ¦ Un archivo mínimo con el nombre del proyecto. Si lo rechazas, el proyecto no se añade.
  Worktree do repositório %@ ¦ Worktree of the repository %@ ¦ Worktree del repositorio %@
  agentes esperam capacidade ¦ agents wait for capacity ¦ los agentes esperan capacidad
  perfis: %@ ¦ profiles: %@ ¦ perfiles: %@
  portas: %@ ¦ ports: %@ ¦ puertos: %@
  sem commits ainda ¦ no commits yet ¦ sin commits todavía
  subpasta %@ ¦ subfolder %@ ¦ subcarpeta %@
  worktree ¦ worktree ¦ worktree
  Conflitos ¦ Conflicts ¦ Conflictos
  Staged ¦ Staged ¦ Preparados
  Modificados ¦ Modified ¦ Modificados
  Novos ¦ New ¦ Nuevos
  Removidos/Renomeados ¦ Removed/Renamed ¦ Eliminados/Renombrados
  Não foi possível mover para o Lixo: %@ ¦ Couldn't move to the Trash: %@ ¦ No se pudo mover a la Papelera: %@
  Outro processo git está usando este repositório (index.lock). Espere ele terminar ou remova o lock antigo. ¦ Another git process is using this repository (index.lock). Wait for it to finish or remove the stale lock. ¦ Otro proceso git está usando este repositorio (index.lock). Espera a que termine o elimina el lock antiguo.
  %@ arquivos selecionados ¦ %@ files selected ¦ %@ archivos seleccionados
  Selecione um arquivo para ver o diff. ¦ Select a file to see its diff. ¦ Selecciona un archivo para ver su diff.
  Descartar ¦ Discard ¦ Descartar
  Commits à frente / atrás do upstream ¦ Commits ahead / behind the upstream ¦ Commits por delante / por detrás del upstream
  sem upstream ¦ no upstream ¦ sin upstream
  Último commit ¦ Last commit ¦ Último commit
  Sem commits ainda ¦ No commits yet ¦ Aún sin commits
  %@ alterações ¦ %@ changes ¦ %@ cambios
  Stage em tudo ¦ Stage all ¦ Preparar todo
  Unstage em tudo ¦ Unstage all ¦ Quitar todo de preparados
  Nada para commitar: a árvore de trabalho está limpa. ¦ Nothing to commit: the working tree is clean. ¦ Nada que commitear: el árbol de trabajo está limpio.
  … e mais %@ (limite de exibição) ¦ … and %@ more (display limit) ¦ … y %@ más (límite de visualización)
  Stage (%@) ¦ Stage (%@) ¦ Preparar (%@)
  Stage ¦ Stage ¦ Preparar
  Unstage (%@) ¦ Unstage (%@) ¦ Quitar de preparados (%@)
  Unstage ¦ Unstage ¦ Quitar de preparados
  Marcar como resolvido (stage) ¦ Mark as resolved (stage) ¦ Marcar como resuelto (preparar)
  Abrir no editor ¦ Open in editor ¦ Abrir en el editor
  App padrão do arquivo ¦ The file's default app ¦ App predeterminada del archivo
  Descartar alterações (%@)… ¦ Discard changes (%@)… ¦ Descartar cambios (%@)…
  Descartar alterações… ¦ Discard changes… ¦ Descartar cambios…
  Descartar as alterações de %@? ¦ Discard the changes to %@? ¦ ¿Descartar los cambios de %@?
  Descartar as alterações de %@ arquivos? ¦ Discard the changes to %@ files? ¦ ¿Descartar los cambios de %@ archivos?
  %@ arquivo(s) voltam ao último commit, incluindo o que está em stage. Não dá para desfazer. ¦ %@ file(s) go back to the last commit, including what is staged. This can't be undone. ¦ %@ archivo(s) vuelven al último commit, incluido lo preparado. No se puede deshacer.
  %@ arquivo(s) novo(s) vão para o Lixo. ¦ %@ new file(s) go to the Trash. ¦ %@ archivo(s) nuevo(s) van a la Papelera.
  Mensagem do commit ¦ Commit message ¦ Mensaje del commit
  Commit (%@) ¦ Commit (%@) ¦ Commit (%@)
  Commit ¦ Commit ¦ Commit
  ⌘↩ faz o commit do que está em stage ¦ ⌘↩ commits what is staged ¦ ⌘↩ hace commit de lo preparado
  Resolva os conflitos antes de commitar. ¦ Resolve the conflicts before committing. ¦ Resuelve los conflictos antes de hacer commit.
  Nada em stage: marque os arquivos que entram no commit. ¦ Nothing staged: tick the files that go into the commit. ¦ Nada preparado: marca los archivos que entran en el commit.
  Os hooks e a assinatura do seu git rodam normalmente. ¦ Your git hooks and signing run as usual. ¦ Los hooks y la firma de tu git se ejecutan como siempre.
  Tirar do stage ¦ Unstage ¦ Quitar de preparados
  Colocar em stage ¦ Stage ¦ Preparar
  binário ¦ binary ¦ binario
  O diff fica oculto no modo de demonstração. ¦ The diff is hidden in demo mode. ¦ El diff se oculta en el modo de demostración.
  Sem diferenças de texto (só o modo do arquivo mudou, ou é binário). ¦ No text differences (only the file mode changed, or it is binary). ¦ Sin diferencias de texto (solo cambió el modo del archivo, o es binario).
  Nenhum projeto chamado %@. ¦ No project called %@. ¦ Ningún proyecto llamado %@.
  Alterações ¦ Changes ¦ Cambios
  Projetos (git) ¦ Projects (git) ¦ Proyectos (git)
  só com as alterações de um projeto abertas: FSEvents, recarrega no máximo a cada 0,5 s e ignora o que o .gitignore cobre ¦ only while a project's changes are open: FSEvents, reloads at most every 0.5 s and ignores what .gitignore covers ¦ solo con los cambios de un proyecto abiertos: FSEvents, recarga como mucho cada 0,5 s e ignora lo que cubre .gitignore
  Mostrar todas (%@) ¦ Show all (%@) ¦ Mostrar todas (%@)
  Branches locais ¦ Local branches ¦ Ramas locales
  Em uso no worktree %@ ¦ Checked out in worktree %@ ¦ En uso en el worktree %@
  Upstream: %@ ¦ Upstream: %@ ¦ Upstream: %@
  upstream removido ¦ upstream gone ¦ upstream eliminado
  em dia ¦ up to date ¦ al día
  Só o working tree principal: nenhum git worktree add neste repositório. ¦ Only the main working tree: no git worktree add in this repository. ¦ Solo el working tree principal: ningún git worktree add en este repositorio.
  Limpar worktrees na Limpeza ¦ Clean up worktrees in Cleanup ¦ Limpiar worktrees en Limpieza
  principal ¦ main ¦ principal
  este projeto ¦ this project ¦ este proyecto
  pasta sumiu ¦ folder gone ¦ carpeta eliminada
  O git ainda lista este worktree; git worktree prune (ou a Limpeza) tira da lista. ¦ Git still lists this worktree; git worktree prune (or Cleanup) takes it off the list. ¦ Git aún lista este worktree; git worktree prune (o Limpieza) lo quita de la lista.
  Medindo o tamanho… ¦ Measuring the size… ¦ Midiendo el tamaño…
  mergeado ¦ merged ¦ fusionado
  não mergeado ¦ not merged ¦ sin fusionar
  em uso ¦ in use ¦ en uso
  Em uso por %@ ¦ In use by %@ ¦ En uso por %@
  bloqueado ¦ locked ¦ bloqueado
  git worktree lock: o git não remove este worktree ¦ git worktree lock: git won't remove this worktree ¦ git worktree lock: git no elimina este worktree
  Em uso ¦ In use ¦ En uso
  Removíveis ¦ Removable ¦ Eliminables
  Outras ¦ Other ¦ Otras
  Outros ¦ Other ¦ Otros
  Mergeado no branch padrão ¦ Merged into the default branch ¦ Fusionado en la rama por defecto
  Remover não usados… ¦ Remove unused… ¦ Eliminar los no usados…
  %@ removíveis ¦ %@ removable ¦ %@ eliminables
  mergeado em %@ ¦ merged into %@ ¦ fusionado en %@
  sai junto com o worktree ¦ goes with its worktree ¦ se va junto con su worktree
  working tree principal ¦ main working tree ¦ working tree principal
  é o checkout atual ¦ it is the current checkout ¦ es el checkout actual
  em uso por %@ ¦ in use by %@ ¦ en uso por %@
  bloqueado (git worktree lock) ¦ locked (git worktree lock) ¦ bloqueado (git worktree lock)
  é o branch padrão ¦ it is the default branch ¦ es la rama por defecto
  aberto num worktree que fica ¦ checked out in a worktree that stays ¦ abierta en un worktree que se queda
  o git não conseguiu ler as alterações ¦ git could not read its changes ¦ git no pudo leer sus cambios
  alterações não commitadas ¦ uncommitted changes ¦ cambios sin commit
  não é mais um worktree deste projeto ¦ no longer a worktree of this project ¦ ya no es un worktree de este proyecto
  o branch não existe mais ¦ the branch no longer exists ¦ la rama ya no existe
  Remover worktrees e branches não usados ¦ Remove unused worktrees and branches ¦ Eliminar worktrees y ramas no usados
  Remover worktrees e branches não usados… ¦ Remove unused worktrees and branches… ¦ Eliminar worktrees y ramas no usados…
  Worktrees mergeados (ou com o upstream removido) que nenhum processo está usando, e branches locais mergeados em %@ sem worktree. Usa git worktree remove e git branch -d: nada é forçado e o git recusa o que tiver trabalho não salvo. Arquivos ignorados dentro de um worktree (node_modules, builds, .env) saem junto com ele. ¦ Merged worktrees (or ones whose upstream is gone) that no process is using, and local branches merged into %@ with no worktree. Uses git worktree remove and git branch -d: nothing is forced and git refuses anything with unsaved work. Ignored files inside a worktree (node_modules, builds, .env) go with it. ¦ Worktrees fusionados (o con el upstream eliminado) que ningún proceso está usando, y ramas locales fusionadas en %@ sin worktree. Usa git worktree remove y git branch -d: nada se fuerza y git rechaza lo que tenga trabajo sin guardar. Los archivos ignorados dentro de un worktree (node_modules, builds, .env) se van con él.
  Lendo worktrees e branches… ¦ Reading worktrees and branches… ¦ Leyendo worktrees y ramas…
  %@ worktrees · %@ branches ¦ %@ worktrees · %@ branches ¦ %@ worktrees · %@ ramas
  Nada para remover: nenhum worktree ou branch mergeado fora de uso. ¦ Nothing to remove: no merged worktree or branch out of use. ¦ Nada que eliminar: ningún worktree ni rama fusionados fuera de uso.
  Permitir worktrees com alterações não commitadas (git worktree remove --force; as alterações se perdem) ¦ Allow worktrees with uncommitted changes (git worktree remove --force; the changes are lost) ¦ Permitir worktrees con cambios sin commit (git worktree remove --force; los cambios se pierden)
  %@ de %@ removidos ¦ %@ of %@ removed ¦ %@ de %@ eliminados
  Instruções para agentes ¦ Agent instructions ¦ Instrucciones para agentes
  O que o .corescope.yml deste projeto pede aos agentes. Com o hook de contexto ligado (Ajustes › Servidor MCP), Claude Code e Codex recebem isto no início de cada sessão; para outros agentes, grave como uma seção marcada no CLAUDE.md / AGENTS.md (o resto do arquivo fica como está). ¦ What this project's .corescope.yml asks of agents. With the context hook on (Settings › MCP server), Claude Code and Codex get this at the start of every session; for other agents, write it as a marked section in CLAUDE.md / AGENTS.md (the rest of the file stays as it is). ¦ Lo que el .corescope.yml de este proyecto pide a los agentes. Con el hook de contexto activado (Ajustes › Servidor MCP), Claude Code y Codex lo reciben al inicio de cada sesión; para otros agentes, guárdalo como una sección marcada en CLAUDE.md / AGENTS.md (el resto del archivo queda igual).
  O texto fica oculto no modo de demonstração. ¦ The text is hidden in demo mode. ¦ El texto se oculta en el modo de demostración.
  Remover seção ¦ Remove section ¦ Quitar sección
  Gravar seção ¦ Write section ¦ Guardar sección
  arquivo não existe (será criado) ¦ file doesn't exist (will be created) ¦ el archivo no existe (se creará)
  seção em dia ¦ section up to date ¦ sección al día
  seção desatualizada ¦ section outdated ¦ sección desactualizada
  sem a seção ¦ no section ¦ sin la sección
  Instruções para agentes… ¦ Agent instructions… ¦ Instrucciones para agentes…
  Hooks dos agentes ¦ Agent hooks ¦ Hooks de los agentes
  %@ não está configurado neste Mac ¦ %@ isn't set up on this Mac ¦ %@ no está configurado en este Mac
  Os hooks rodam o corescope deste app; cada arquivo ganha um backup antes de mudar e só as entradas do CoreScope são mexidas. Agentes sem hooks recebem o mesmo pelo MCP (agent_context) ou pela seção no CLAUDE.md / AGENTS.md de cada projeto. ¦ The hooks run this app's corescope; each file is backed up before it changes and only CoreScope's entries are touched. Agents without hooks get the same through MCP (agent_context) or the section in each project's CLAUDE.md / AGENTS.md. ¦ Los hooks ejecutan el corescope de esta app; cada archivo recibe una copia de seguridad antes de cambiar y solo se tocan las entradas de CoreScope. Los agentes sin hooks reciben lo mismo por MCP (agent_context) o por la sección en el CLAUDE.md / AGENTS.md de cada proyecto.
  Contexto do projeto no início da sessão ¦ Project context at session start ¦ Contexto del proyecto al iniciar la sesión
  Esperar folga antes de comandos pesados ¦ Wait for room before heavy commands ¦ Esperar holgura antes de comandos pesados
  O agente recebe o que o .corescope.yml pede: capacidade, portas, perfis, serviços e logs. ¦ The agent gets what the .corescope.yml asks for: capacity, ports, profiles, services and logs. ¦ El agente recibe lo que pide el .corescope.yml: capacidad, puertos, perfiles, servicios y logs.
  Builds e testes esperam CPU e memória normalizarem nos projetos com agents.wait_for_capacity. ¦ Builds and tests wait for CPU and memory to settle in projects with agents.wait_for_capacity. ¦ Builds y tests esperan a que la CPU y la memoria se normalicen en los proyectos con agents.wait_for_capacity.
  O Codex só roda hooks que você aprovou: abra o Codex, digite /hooks e confie nos do CoreScope (de novo se o app mudar de lugar). ¦ Codex only runs hooks you approved: open Codex, type /hooks and trust CoreScope's (again if the app moves). ¦ Codex solo ejecuta hooks que aprobaste: abre Codex, escribe /hooks y confía en los de CoreScope (de nuevo si la app cambia de lugar).
  O Codex confia nos hooks do CoreScope. ¦ Codex trusts CoreScope's hooks. ¦ Codex confía en los hooks de CoreScope.
  O Codex ainda não roda estes hooks: abra o Codex, digite /hooks e confie nos do CoreScope. Depois disso eles rodam em toda sessão. ¦ Codex doesn't run these hooks yet: open Codex, type /hooks and trust CoreScope's. After that they run in every session. ¦ Codex aún no ejecuta estos hooks: abre Codex, escribe /hooks y confía en los de CoreScope. Después se ejecutan en cada sesión.
  Não foi possível ler %@ ¦ Couldn't read %@ ¦ No se pudo leer %@
  %@ não é um JSON válido; corrija o arquivo antes. ¦ %@ isn't valid JSON; fix the file first. ¦ %@ no es un JSON válido; corrige el archivo antes.
  1 arquivo ¦ 1 file ¦ 1 archivo
  %@ arquivos ¦ %@ files ¦ %@ archivos
  Alteração anterior ¦ Previous change ¦ Cambio anterior
  Próxima alteração ¦ Next change ¦ Siguiente cambio
  novo ¦ new ¦ nuevo
  removido ¦ deleted ¦ eliminado
  Arquivo binário: sem diff de texto. ¦ Binary file: no text diff. ¦ Archivo binario: sin diff de texto.
  Só renomeado, sem mudar o conteúdo. ¦ Only renamed, content unchanged. ¦ Solo renombrado, sin cambiar el contenido.
  Sem diferenças de texto (só o modo do arquivo mudou). ¦ No text differences (only the file mode changed). ¦ Sin diferencias de texto (solo cambió el modo del archivo).
  Diff cortado: o arquivo tem alterações demais para mostrar. ¦ Diff cut: the file has too many changes to show. ¦ Diff recortado: el archivo tiene demasiados cambios para mostrar.
  1 linha sem mudança ¦ 1 unchanged line ¦ 1 línea sin cambios
  %@ linhas sem mudança ¦ %@ unchanged lines ¦ %@ líneas sin cambios
  Mostrar o arquivo inteiro ¦ Show the whole file ¦ Mostrar el archivo entero
  Sem alterações ¦ No changes ¦ Sin cambios
  %@ conflitos ¦ %@ conflicts ¦ %@ conflictos
  %@ em stage ¦ %@ staged ¦ %@ preparados
  %@ modificados ¦ %@ modified ¦ %@ modificados
  %@ novos ¦ %@ new ¦ %@ nuevos
  %@ removidos ¦ %@ deleted ¦ %@ eliminados
  Abrir as alterações ¦ Open the changes ¦ Abrir los cambios
  Nada para mostrar. ¦ Nothing to show. ¦ Nada que mostrar.
  Clique para abrir as alterações ¦ Click to open the changes ¦ Haz clic para abrir los cambios
  PROJETOS ¦ PROJECTS ¦ PROYECTOS
  Projetos no painel ¦ Projects in the panel ¦ Proyectos en el panel
  Adicionar projetos… ¦ Add projects… ¦ Añadir proyectos…
  conflitos ¦ conflicts ¦ conflictos
  em stage ¦ staged ¦ preparados
  modificados ¦ modified ¦ modificados
  novos ¦ new ¦ nuevos
  removidos ¦ deleted ¦ eliminados
  branch: %@ → %@ ¦ branch: %@ → %@ ¦ rama: %@ → %@
  novo commit em %@ ¦ new commit on %@ ¦ nuevo commit en %@
  novo commit ¦ new commit ¦ nuevo commit
  sem alterações agora ¦ no changes now ¦ sin cambios ahora
  1 alteração agora ¦ 1 change now ¦ 1 cambio ahora
  %@ alterações agora ¦ %@ changes now ¦ %@ cambios ahora
  Notificar alterações ¦ Notify changes ¦ Notificar cambios
  Desligado ¦ Off ¦ Desactivado
  A cada 1 min ¦ Every 1 min ¦ Cada 1 min
  A cada 5 min ¦ Every 5 min ¦ Cada 5 min
  A cada 15 min ¦ Every 15 min ¦ Cada 15 min
  Alterações nos projetos ¦ Project changes ¦ Cambios en los proyectos
  Alterações em %@ ¦ Changes in %@ ¦ Cambios en %@
  Desligadas por padrão. Uma notificação local por projeto no máximo a cada intervalo, só quando algo mudou desde a última (novos, modificados, em stage, commits, troca de branch) — salvar um arquivo já modificado não conta. Clicar abre as alterações. ¦ Off by default. At most one local notification per project per interval, only when something changed since the last one (new, modified, staged, commits, branch switch) — saving an already modified file doesn't count. Clicking opens the changes. ¦ Desactivadas por defecto. Como mucho una notificación local por proyecto por intervalo, solo cuando algo cambió desde la última (nuevos, modificados, preparados, commits, cambio de rama) — guardar un archivo ya modificado no cuenta. Al hacer clic se abren los cambios.
  Notifica alterações a cada %@ min ¦ Notifies changes every %@ min ¦ Notifica cambios cada %@ min
  Claude Code instalado (claude -p) ¦ Installed Claude Code (claude -p) ¦ Claude Code instalado (claude -p)
  Codex instalado (codex exec) ¦ Installed Codex (codex exec) ¦ Codex instalado (codex exec)
  Ollama (local) ¦ Ollama (local) ¦ Ollama (local)
  LM Studio (local) ¦ LM Studio (local) ¦ LM Studio (local)
  Crie uma chave em platform.claude.com › API keys. ¦ Create a key at platform.claude.com › API keys. ¦ Crea una clave en platform.claude.com › API keys.
  Crie uma chave em platform.openai.com › API keys. ¦ Create a key at platform.openai.com › API keys. ¦ Crea una clave en platform.openai.com › API keys.
  Crie uma chave em aistudio.google.com › Get API key. ¦ Create a key at aistudio.google.com › Get API key. ¦ Crea una clave en aistudio.google.com › Get API key.
  Usa o login do próprio Claude Code; nenhuma chave aqui. ¦ Uses Claude Code's own login; no key here. ¦ Usa el inicio de sesión de Claude Code; ninguna clave aquí.
  Usa o login do próprio Codex; nenhuma chave aqui. ¦ Uses Codex's own login; no key here. ¦ Usa el inicio de sesión de Codex; ninguna clave aquí.
  Roda no seu Mac; nada sai da máquina. ¦ Runs on your Mac; nothing leaves it. ¦ Se ejecuta en tu Mac; nada sale de la máquina.
  O Codex não devolveu uma mensagem. ¦ Codex returned no message. ¦ Codex no devolvió ningún mensaje.
  Falta a chave da API no Keychain. ¦ The API key is missing from the Keychain. ¦ Falta la clave de la API en el Llavero.
  Endereço inválido: %@ ¦ Invalid address: %@ ¦ Dirección no válida: %@
  Sem resposta. ¦ No response. ¦ Sin respuesta.
  A resposta veio sem texto. ¦ The response had no text. ¦ La respuesta llegó sin texto.
  %@ não foi encontrado neste Mac. ¦ %@ wasn't found on this Mac. ¦ No se encontró %@ en este Mac.
  %@ demorou demais. ¦ %@ took too long. ¦ %@ tardó demasiado.
  IA (opcional) ¦ AI (optional) ¦ IA (opcional)
  Gerar mensagens de commit com IA ¦ Generate commit messages with AI ¦ Generar mensajes de commit con IA
  Desligado por padrão: é o único recurso do CoreScope que pode mandar código para fora do Mac. Ligado, nada é enviado sozinho — só quando você clica em Gerar mensagem, e na primeira vez com cada provedor o CoreScope mostra exatamente o que vai: o nome do repositório, a branch, a lista de arquivos e o diff em stage (sem lockfiles nem binários, cortado no limite abaixo). O commit continua sendo um clique seu. ¦ Off by default: it is the only CoreScope feature that can send code off the Mac. When on, nothing is sent by itself — only when you click Generate message, and the first time with each provider CoreScope shows exactly what goes: the repository's name, the branch, the file list and the staged diff (no lockfiles or binaries, cut at the limit below). Committing is still your click. ¦ Desactivado por defecto: es la única función de CoreScope que puede enviar código fuera del Mac. Activado, nada se envía solo — solo cuando haces clic en Generar mensaje, y la primera vez con cada proveedor CoreScope muestra exactamente lo que se envía: el nombre del repositorio, la rama, la lista de archivos y el diff preparado (sin lockfiles ni binarios, recortado al límite de abajo). El commit sigue siendo un clic tuyo.
  Provedor ¦ Provider ¦ Proveedor
  Modelo ¦ Model ¦ Modelo
  padrão do provedor ¦ provider's default ¦ predeterminado del proveedor
  Sugestões de modelos rápidos e baratos; confira os nomes atuais na documentação do provedor. ¦ Suggestions of fast, inexpensive models; check the current names in the provider's documentation. ¦ Sugerencias de modelos rápidos y baratos; comprueba los nombres actuales en la documentación del proveedor.
  Chave da API ¦ API key ¦ Clave de la API
  salva no Keychain ¦ saved in the Keychain ¦ guardada en el Llavero
  cole a chave ¦ paste the key ¦ pega la clave
  Endereço ¦ Address ¦ Dirección
  A chave fica só no Keychain do macOS, nunca em preferências, arquivos ou logs. ¦ The key lives only in the macOS Keychain, never in preferences, files or logs. ¦ La clave vive solo en el Llavero de macOS, nunca en preferencias, archivos ni logs.
  Idioma da mensagem ¦ Message language ¦ Idioma del mensaje
  O do app ¦ The app's ¦ El de la app
  Limite do diff enviado ¦ Diff size limit ¦ Límite del diff enviado
  Instruções ¦ Instructions ¦ Instrucciones
  Restaurar padrão ¦ Restore default ¦ Restaurar predeterminado
  Testar conexão ¦ Test connection ¦ Probar conexión
  Pedir confirmação de novo ¦ Ask again ¦ Volver a pedir confirmación
  Mostra outra vez o que será enviado antes do próximo envio a cada provedor. ¦ Shows again what will be sent before the next request to each provider. ¦ Vuelve a mostrar lo que se enviará antes del próximo envío a cada proveedor.
  O teste manda só uma frase curta, nenhum código. ¦ The test sends one short sentence, no code. ¦ La prueba envía solo una frase corta, nada de código.
  Respondeu: %@ ¦ Replied: %@ ¦ Respondió: %@
  Enviar para %@? ¦ Send to %@? ¦ ¿Enviar a %@?
  Isto sai do seu Mac e vai para o provedor escolhido, que processa conforme os termos dele. Só desta vez a cada provedor o CoreScope pergunta; depois, Gerar mensagem envia direto. ¦ This leaves your Mac for the provider you chose, which processes it under its own terms. CoreScope asks only this once per provider; after that, Generate message sends right away. ¦ Esto sale de tu Mac hacia el proveedor elegido, que lo procesa según sus términos. CoreScope pregunta solo esta vez por proveedor; después, Generar mensaje envía directamente.
  Vai para o servidor local configurado; nada sai do Mac. ¦ Goes to the configured local server; nothing leaves the Mac. ¦ Va al servidor local configurado; nada sale del Mac.
  Repositório %@ · %@ arquivos · %@ do diff%@ ¦ Repository %@ · %@ files · %@ of diff%@ ¦ Repositorio %@ · %@ archivos · %@ de diff%@
  (cortado) ¦ (cut) ¦ (recortado)
  Enviar e gerar ¦ Send and generate ¦ Enviar y generar
  Gerar mensagem ¦ Generate message ¦ Generar mensaje
  Escreve a mensagem a partir do diff em stage (%@). Você revisa antes de commitar. ¦ Writes the message from the staged diff (%@). You review it before committing. ¦ Escribe el mensaje a partir del diff preparado (%@). Lo revisas antes del commit.
  Não deu para gerar a mensagem: %@ ¦ Couldn't generate the message: %@ ¦ No se pudo generar el mensaje: %@
  """
