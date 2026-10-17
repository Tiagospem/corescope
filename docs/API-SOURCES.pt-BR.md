# APIs e fontes

*English: [API-SOURCES.md](API-SOURCES.md)*

Verificadas em 16/10/2026, junto aos headers do SDK macOS local.

| Uso | Fonte |
|---|---|
| CPU total | `host_statistics(HOST_CPU_LOAD_INFO)`; [Mach host statistics](https://developer.apple.com/documentation/kernel/1502863-host_statistics64) e `mach/host_info.h` |
| Memória | `host_statistics64(HOST_VM_INFO64)`, `hw.memsize`, `vm.swapusage`; estruturas compiladas contra o SDK real, sem layout Mach copiado à mão |
| Processos | `libproc.h`, `sys/proc_info.h`, `sys/resource.h`: `proc_listpids`, `proc_pidinfo`, `proc_pidpath`, `proc_pid_rusage` |
| CPU por processo | RUSAGE retorna tempo absoluto Mach. Conversão por `mach_timebase_info`; [XNU fill_task_rusage](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c). Multiplicação intermediária de 128 bits evita overflow; teste de carga real valida a escala em Apple Silicon |
| Pressão | [DISPATCH_SOURCE_TYPE_MEMORYPRESSURE](https://developer.apple.com/documentation/Dispatch/DISPATCH_SOURCE_TYPE_MEMORYPRESSURE). Estado desconhecido até evento, sem inferir “normal” da falta de evento |
| Térmico | [ProcessInfo thermal state](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html), lido em cada ciclo; sem valores Celsius inventados |
| I/O físico | [IOBlockStorageDriver](https://developer.apple.com/documentation/kernel/ioblockstoragedriver), propriedades públicas [Statistics](https://developer.apple.com/documentation/iokit/ioblockstoragedriver_h_user-space/defines?language=objc); ID de registro identifica cada driver. IOMedia filho fornece nome do dispositivo |
| Volumes | `getmntinfo(MNT_NOWAIT)` / `statfs`, leitura do cache do kernel para evitar esperar I/O lento de dispositivos externos. `f_bavail` é espaço disponível ao usuário |
| Painel | [NSPanel](https://developer.apple.com/documentation/appkit/nspanel), nonactivatingPanel, canJoinAllSpaces, fullScreenAuxiliary e NSScreen.visibleFrame |
| Início de sessão | [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp?language=objc). Só register/unregister ao usuário mudar o toggle; sem helper privilegiado |

Dependências Rust diretas: serde e serde_json; cc apenas em build. Versões transitivas fixadas em Cargo.lock. Nenhum sysinfo, coleta de argumentos, framework web ou serviço externo.

Limitações: `phys_footprint` não é RSS; I/O atribuído por processo não é a soma exata do I/O físico; volumes APFS compartilham blocos. Contadores podem reiniciar após dispositivos sumirem. Leituras sem baseline, falha de acesso e falta de suporte produzem valor ausente, nunca zero simulado. `pkg_idle_wkups` mede despertares do pacote atribuídos ao processo, não todos os timers; `interrupt_wkups` é outro contador. Campos brutos de energia não são convertidos em watts sem unidade confiável.

## NVMe SMART adicionado após investigação

Fonte de ABI: header público Apple `IOKit/storage/nvme/NVMeSMARTLibExternal.h` no SDK local. Usa `kIONVMeSMARTUserClientTypeID`, `kIONVMeSMARTInterfaceID`, `NVMeSMARTData.TEMPERATURE` e `SMARTReadData`. O buffer de 512 bytes vem do header, não de estrutura copiada de terceiro.

Fluxo de referência independente: [Smartmontools Darwin](https://www.smartmontools.org/static/doxygen/os__darwin_8cpp_source.html). Nossa implementação é própria, sem redistribuir código/binário do Disk Drill ou smartctl. [Explicação oficial CleverFiles](https://www.cleverfiles.com/help/monitor-smart-status-disk-health/) e evidências REA estão no relatório específico.
