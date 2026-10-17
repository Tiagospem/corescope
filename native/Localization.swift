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
  """
