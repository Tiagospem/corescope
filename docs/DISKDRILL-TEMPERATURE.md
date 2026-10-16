# Temperatura de discos: investigação do Disk Drill

Data: 16/10/2026. Escopo: análise estática, somente leitura, do Disk Drill instalado e consulta a fontes públicas. Nenhum disco foi interrogado por esta investigação; nenhuma preferência, helper, extensão, permissão ou configuração SMART foi alterada. O app e seus executáveis não foram executados. A sessão REA foi fechada ao concluir.

## Conclusão

O Disk Drill instalado inclui **smartctl/Smartmontools** e código que reconhece os resultados ATA e NVMe dessa ferramenta. Isso também é confirmado pela [documentação oficial da CleverFiles](https://www.cleverfiles.com/help/monitor-smart-status-disk-health/), na seção “What Mechanism Does Disk Drill for macOS Use to Integrate With S.M.A.R.T.”. Não se trata de uma temperatura universal que o macOS publique como propriedade comum do disco.

Há uma oportunidade melhor que depender do Disk Drill: o SDK Apple instalado fornece a interface **NVMeSMARTLibExternal.h**, com leitura SMART e campo de temperatura. CoreScope pode usar esse contrato do SDK por um pequeno adaptador C próprio. O funcionamento com o SSD Apple interno e com o Kingston externo precisa ser verificado por leitura real no host; a análise estática, sozinha, não demonstra acesso, temperatura ou compatibilidade.

## Resultado posterior no CoreScope

Após esta investigação estática, o adaptador independente do CoreScope leu os dois SSDs usando `SMARTReadData`, sem root: Apple 50,85 °C e Kingston 47,85 °C às 09:55:31. Isso valida esses dispositivos e essa conexão no host observado; não prova suporte universal. A evidência de execução e suas limitações estão em [VALIDATION.md](VALIDATION.md). As seções abaixo preservam o escopo e as incertezas da investigação estática original.

## Alvos e evidências

Disk Drill **6.3**, build **6.3.2326**, identificado por `Contents/Info.plist`. Caminhos abaixo são relativos a `/Applications/Disk Drill.app`.

| Item | Resultado observado | Referência |
| --- | --- | --- |
| Executável principal | Mach-O universal, fatia arm64 selecionada, SHA-256 `7c9721f7db6afb2b66fe5606ca7a06c1b693a6fa5eefb794b786bb4a09a230ad` | REA `open_binary` |
| Imports do principal | `IOCreatePlugInInterfaceForService`, `IORegistryEntryCreateCFProperty`, `IOBSDNameMatching`, `IOServiceGetMatchingService`, `IODestroyPlugInInterface`, `posix_spawn`, APIs de autorização | REA `inspect_macho`, `ev_40b5d7747b34e93f3b4c1055b3e7dc3d37b65a7d8a5538adc6639eadc9717728` |
| smartctl incluído | `Contents/Library/LoginItems/SmartDaemon.app/Contents/MacOS/smartctl`; SHA-256 `82dca2cab9e0b67e15960b4b119f58fa96f4d23e5f49eef499b8a13499629575`; importa `IOCreatePlugInInterfaceForService` | REA `inspect_macho`, `ev_a69e5eb58a28f5d7ad5bd57176f0e84b115610b125acc2eb428a7a0e40bd94e9` |
| Tabela de atributos | `smartattrs.plist` associa 190 a Airflow Temperature e 194 a HDA temperature, ambos com formato Temperature | REA `inspect_plist`, `ev_1f7e093783efd43ee5ae55cdb06294bcafac8c97c934dfb0c391ca9663e980a3` |
| Serviço empacotado | LaunchDaemon `com.cleverfiles.BackService_12`, `KeepAlive=true`, programa `Contents/Helpers/BackService_12.app/Contents/MacOS/cfbackd` | REA `inspect_plist`, `ev_b29e0296ca01e56b2ade832fbb350967ad8ba6a99eb847abfdddae5562349267` |

Os IDs acima são observações reais do REA, não IDs inventados para a pesquisa em shell. A inspeção do plist registra o arquivo em `normalized_result.source_path`; o `subject` genérico do REA pode continuar sendo o binário ativo da sessão.

### Evidência estática complementar em shell

`strings -a` no principal encontrou `SmartctlProvider`, `SmartctlAttribute`, `SmartmontoolsPath`, `Contents/MacOS/smartctl`, `/usr/local/bin/smartctl`, `/usr/local/sbin/smartctl`, `/usr/sbin/smartctl`, `smartctl detected at %@`, `ata_smart_attributes`, `nvme_smart_health_information_log`, `smart_status.passed`, `temperature` e `smartctl.messages.string`.

Também aparecem `IOATASMARTInterface` nos tipos Objective-C, `SMART Capable` e mensagem de formato de temperatura SMART desconhecido. São evidências de rotas implementadas/candidatas, não prova de qual rota foi usada nesta máquina.

O smartctl incluído contém identificador de build **7.5, 2025-04-30, r5715**, textos `NVMe SMART Capable`, `GetLogPage failed`, e referências a bridges ASMedia/JMicron/Realtek. A presença desses nomes **não prova suporte no backend Darwin**. O arquivo `smartctl_copyrights.txt` identifica Smartmontools e sua licença. Nenhum código ou executável do Disk Drill foi copiado para CoreScope.

`codesign -d --entitlements :-` no smartctl mostrou `disable-library-validation` e `personal-information.addressbook`; isso não demonstra autorização SMART nem necessidade dessas permissões para CoreScope. A existência de LaunchDaemon e imports de autorização também não prova que leituras de temperatura necessitem root.

## Rota pública verificada no SDK Apple

Header instalado:

`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/IOKit.framework/Versions/A/Headers/storage/nvme/NVMeSMARTLibExternal.h`

O header declara acesso por tarefas fora do kernel e fornece:

- Propriedade `kIOPropertyNVMeSMARTCapableKey`: `NVMe SMART Capable`.
- `kIONVMeSMARTUserClientTypeID`: `AA0FA6F9-C2D6-457F-B10B-59A13253292F`.
- `kIONVMeSMARTInterfaceID`: `CCD1DB19-FD9A-4DAF-BF95-12454B230AB6`.
- `NVMeSMARTData`, estrutura empacotada de 512 bytes, cujo campo `TEMPERATURE` é um `uint16_t` após `CRITICAL_WARNING`.
- `IONVMeSMARTInterface.SMARTReadData(interface, NVMeSMARTData*)`.
- `IONVMeSMARTInterface.GetLogPage(interface, buffer, logPageID, numDWords)`; `numDWords` é baseado em zero.

Usar o header do SDK evita reconstruir manualmente ABI de um binário. A temperatura NVMe é expressa em Kelvin; a apresentação em Celsius exige conversão, com validação de leitura e de valores sentinela. Retornar indisponível em falha, jamais fabricar zero graus.

A [implementação pública Darwin de Smartmontools](https://www.smartmontools.org/static/doxygen/os__darwin_8cpp_source.html) corrobora o percurso: encontra o dispositivo pelo nome BSD, sobe os pais no plano IOService até SMART-capable, cria plugin, consulta a interface NVMe e chama GetLogPage. A enumeração usa IOBlockStorageDevice. Seu backend SCSI nessa revisão retorna indisponível. Essa fonte é uma revisão publicada de 2025, não uma afirmação sobre qualquer futuro backend.

Fluxo de implementação independente sugerido:

1. Partir do nome BSD do disco físico, usar `IOBSDNameMatching` e obter o serviço correspondente.
2. Percorrer pais `kIOServicePlane`, verificando a propriedade NVMe SMART em cada serviço. Liberar cada referência adquirida; limitar a travessia e tratar desconexão.
3. Criar `IOCFPlugInInterface` com o user client NVMe, consultar `IONVMeSMARTInterface` com `QueryInterface`, verificar o retorno e ponteiros.
4. Ler `SMARTReadData`; se necessário, avaliar GetLogPage com log 2 e 127 dwords para 512 bytes. Esta alternativa deve ser validada em runtime, não assumida.
5. Converter a temperatura apenas após sucesso e associar a amostra ao disco físico correto. APFS pode expor volumes virtuais diferentes do backing device.
6. Liberar interface via `Release`, plugin via `IODestroyPlugInInterface`, objetos IOKit via `IOObjectRelease`.

Isso é uma proposta baseada no contrato público, não pseudocódigo extraído do Disk Drill.

## Interno Apple, externo Kingston e permissões

| Caso | O que se pode concluir agora | O que falta provar |
| --- | --- | --- |
| SSD Apple interno NVMe | Existe API de leitura adequada no SDK | Serviço exposto, leitura sem privilégio e valor válido neste macOS |
| Kingston NVMe por Thunderbolt/USB4 com PCIe exposto | Pode apresentar a mesma interface NVMe | Topologia real do adaptador e sucesso de leitura |
| Kingston via bridge USB/SCSI | Suporte depende de bridge, driver e backend; nomes no binário não bastam | Pass-through efetivo disponível neste host |
| Permissão de leitura | Não é correto inferir root apenas porque Disk Drill tem helper | Código de retorno da leitura sem privilégio |

A documentação CleverFiles menciona uma extensão SAT para alguns externos e desaconselha seu uso geral a partir do macOS 11 por falta de manutenção. Essa investigação não instalou nem recomenda instalar essa extensão, reduzir segurança do boot ou reutilizar os helpers do Disk Drill. A API pública deve ser tentada com o usuário normal; falhas devem permanecer explícitas.

Integração opcional com **smartctl instalado independentemente** pode ser alternativa futura. Ler JSON, usar argumentos fixos de consulta, prazo limitado, associação por disco físico e tratamento de falhas por dispositivo. Não adotar o smartctl interno do Disk Drill como dependência de CoreScope. Seu caminho, versão e existência pertencem ao outro aplicativo.

## Limites e questões pendentes

REA abriu e identificou os binários; inspeções Mach-O/plist funcionaram. `search_strings` pelo provider nativo profundo retornou `provider_unavailable`: Ghidra não configurado, Hopper ausente, IDA não configurado. Há ainda limitação declarada do provider Ghidra para selecionar fatia em Mach-O universal. Nenhum engine foi instalado. Strings em shell são explicitamente fallback, não decompilação REA.

- **Respondido:** fonte tecnológica do Disk Drill — Smartmontools empacotado, parsing SMART e imports IOKit.
- **Respondido:** há API pública no SDK local que permite uma implementação própria de leitura NVMe.
- **Parcial:** fluxo interno exato, argumentos do subprocesso e ordem de fallback do Disk Drill; requer análise profunda ou observação controlada.
- **Não testado nesta investigação:** temperaturas reais, permissões efetivas e suporte dos dois dispositivos locais. A implementação e validação runtime de CoreScope são atividades separadas.
- **Não estabelecido:** envolvimento de cfbackd na temperatura, frequência real observada, transporte do adaptador Kingston, precisão/calibração dos sensores.

As conclusões não prometem suporte universal a discos externos nem equivalência funcional ao Disk Drill.
