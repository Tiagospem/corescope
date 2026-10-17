#include "macos.h"
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <sys/sysctl.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <libproc.h>
#include <unistd.h>
#include <pwd.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

static mach_timebase_info_data_t timebase;
static pthread_once_t timebase_once=PTHREAD_ONCE_INIT;
static void init_timebase(void){mach_timebase_info(&timebase);}
static uint64_t to_ns(uint64_t ticks){pthread_once(&timebase_once,init_timebase);return timebase.denom ? (uint64_t)((__uint128_t)ticks*timebase.numer/timebase.denom) : 0;}
void os_host(CSHost *o) {
 memset(o,0,sizeof(*o));
 mach_port_t host=mach_host_self();
 host_cpu_load_info_data_t cpu={0}; mach_msg_type_number_t n=HOST_CPU_LOAD_INFO_COUNT;
 o->cpu_ok=host_statistics(host,HOST_CPU_LOAD_INFO,(host_info_t)&cpu,&n)==KERN_SUCCESS;
 if(o->cpu_ok) for(int i=0;i<4;i++)o->ticks[i]=cpu.cpu_ticks[i];
 vm_statistics64_data_t vm={0}; n=HOST_VM_INFO64_COUNT;
 o->memory_ok=host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&vm,&n)==KERN_SUCCESS;
 vm_size_t page=0; host_page_size(host,&page);
 mach_port_deallocate(mach_task_self(),host);
 if(o->memory_ok){o->active=(uint64_t)vm.active_count*page;o->wired=(uint64_t)vm.wire_count*page;o->compressed=(uint64_t)vm.compressor_page_count*page;
  o->internal=(uint64_t)vm.internal_page_count*page;o->purgeable=(uint64_t)vm.purgeable_count*page;o->external=(uint64_t)vm.external_page_count*page;}
 size_t len=sizeof(o->physical); if(sysctlbyname("hw.memsize",&o->physical,&len,NULL,0))o->memory_ok=0;
 len=sizeof(o->cores);sysctlbyname("hw.logicalcpu",&o->cores,&len,NULL,0);
 struct xsw_usage sw={0};len=sizeof(sw);o->swap_ok=sysctlbyname("vm.swapusage",&sw,&len,NULL,0)==0;o->swap=sw.xsu_used;
 int level=-1;len=sizeof(level);if(sysctlbyname("kern.memorystatus_level",&level,&len,NULL,0))level=-1;o->memory_level=level;
}
int os_core_ticks(uint64_t *ticks,int cap){
 natural_t count=0;processor_info_array_t info=NULL;mach_msg_type_number_t n=0;
 mach_port_t host=mach_host_self();
 kern_return_t r=host_processor_info(host,PROCESSOR_CPU_LOAD_INFO,&count,&info,&n);
 mach_port_deallocate(mach_task_self(),host);
 if(r!=KERN_SUCCESS||!info)return -1;
 processor_cpu_load_info_t load=(processor_cpu_load_info_t)info;int out=0;
 for(natural_t i=0;i<count&&(int)i<cap;i++,out++)for(int s=0;s<CPU_STATE_MAX;s++)ticks[i*4+s]=load[i].cpu_ticks[s];
 vm_deallocate(mach_task_self(),(vm_address_t)info,(vm_size_t)n*sizeof(integer_t));
 return out;
}
int os_core_kinds(uint8_t *out,int cap){
 memset(out,0,(size_t)cap);
 io_registry_entry_t cpus=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/cpus");
 if(!cpus)return 0;
 io_iterator_t it=0;int found=0;
 if(IORegistryEntryGetChildIterator(cpus,kIODeviceTreePlane,&it)==KERN_SUCCESS){
  io_object_t cpu;
  while((cpu=IOIteratorNext(it))){
   CFTypeRef id=IORegistryEntryCreateCFProperty(cpu,CFSTR("logical-cpu-id"),kCFAllocatorDefault,0);
   CFTypeRef kind=IORegistryEntryCreateCFProperty(cpu,CFSTR("cluster-type"),kCFAllocatorDefault,0);
   int64_t index=-1;
   if(id&&CFGetTypeID(id)==CFNumberGetTypeID())CFNumberGetValue(id,kCFNumberSInt64Type,&index);
   if(kind&&CFGetTypeID(kind)==CFDataGetTypeID()&&CFDataGetLength(kind)>0&&index>=0&&index<cap){
    uint8_t k=CFDataGetBytePtr(kind)[0];if(k=='P'||k=='E'){out[index]=k;found++;}
   }
   if(id)CFRelease(id);if(kind)CFRelease(kind);IOObjectRelease(cpu);
  }
  IOObjectRelease(it);
 }
 IOObjectRelease(cpus);return found;
}
void os_perflevels(uint32_t *level0,uint32_t *level1){
 size_t len=sizeof(uint32_t);*level0=0;*level1=0;
 if(sysctlbyname("hw.perflevel0.logicalcpu",level0,&len,NULL,0))*level0=0;
 len=sizeof(uint32_t);if(sysctlbyname("hw.perflevel1.logicalcpu",level1,&len,NULL,0))*level1=0;
}
int os_pids(int32_t *o,int cap){int n=proc_listpids(PROC_ALL_PIDS,0,o,cap*sizeof(int32_t));return n>0?n/(int)sizeof(int32_t):-1;}
int os_process(int32_t pid,CSProcess *o){
 memset(o,0,sizeof(*o));struct proc_bsdinfo b={0};
 if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b))return errno?errno:ESRCH;
 o->pid=pid;o->ppid=b.pbi_ppid;o->uid=b.pbi_uid;o->flags=b.pbi_flags;o->start=b.pbi_start_tvsec*1000000+b.pbi_start_tvusec;
 strlcpy(o->name,b.pbi_name[0]?b.pbi_name:b.pbi_comm,sizeof(o->name));
 proc_pidpath(pid,o->path,sizeof(o->path));
 struct passwd pw,*found=NULL;char buf[4096];
 if(getpwuid_r(b.pbi_uid,&pw,buf,sizeof(buf),&found)==0&&found)strlcpy(o->user,pw.pw_name,sizeof(o->user));
 struct proc_taskinfo t={0};errno=0;o->task_ok=proc_pidinfo(pid,PROC_PIDTASKINFO,0,&t,sizeof(t))==sizeof(t);
 o->task_error=o->task_ok?0:errno;
 if(o->task_ok){o->cpu_ns=t.pti_total_user+t.pti_total_system;o->resident=t.pti_resident_size;o->threads=t.pti_threadnum;}
 // v6 adds per-process energy (ri_energy_nj); its first fields are v4's, so v4 is the fallback.
 o->sid=getsid(pid);
 struct rusage_info_v6 r={0};errno=0;o->energy_ok=proc_pid_rusage(pid,RUSAGE_INFO_V6,(rusage_info_t*)&r)==0;
 o->usage_ok=o->energy_ok||proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t*)&r)==0;
 o->usage_error=o->usage_ok?0:errno;
 if(o->usage_ok){o->cpu_ns=to_ns(r.ri_user_time+r.ri_system_time);o->footprint=r.ri_phys_footprint;o->read_bytes=r.ri_diskio_bytesread;o->write_bytes=r.ri_diskio_byteswritten;o->wakeups=r.ri_pkg_idle_wkups;o->energy_nj=o->energy_ok?r.ri_energy_nj:0;}
 return 0;
}
int os_volumes(CSVolume *o,int cap){
 // getmntinfo() reuses one process-wide buffer and crashes when sampled from two threads.
 struct statfs *mounts=NULL;int n=getmntinfo_r_np(&mounts,MNT_NOWAIT);if(n<=0){free(mounts);return -1;}int j=0;
 for(int i=0;i<n&&j<cap;i++){
  struct statfs *m=&mounts[i];if(!(m->f_flags&MNT_LOCAL)||strncmp(m->f_mntfromname,"/dev/",5)!=0)continue;
  CSVolume *v=&o[j++];memset(v,0,sizeof(*v));v->total=m->f_blocks*(uint64_t)m->f_bsize;v->available=m->f_bavail*(uint64_t)m->f_bsize;
  strlcpy(v->device,m->f_mntfromname,sizeof(v->device));strlcpy(v->mount,m->f_mntonname,sizeof(v->mount));strlcpy(v->kind,m->f_fstypename,sizeof(v->kind));
 }free(mounts);return j;
}
static int number(CFDictionaryRef d,CFStringRef key,uint64_t *o){CFTypeRef v=CFDictionaryGetValue(d,key);return v&&CFGetTypeID(v)==CFNumberGetTypeID()&&CFNumberGetValue(v,kCFNumberSInt64Type,o);}
int os_disks(CSDisk *out,int cap){
 io_iterator_t it=0;if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOBlockStorageDriver"),&it)!=KERN_SUCCESS)return -1;
 int n=0;io_object_t obj;
 while((obj=IOIteratorNext(it))){
  if(n<cap){CSDisk *o=&out[n++];memset(o,0,sizeof(*o));IORegistryEntryGetRegistryEntryID(obj,&o->id);io_name_t name;IORegistryEntryGetName(obj,name);strlcpy(o->name,name,sizeof(o->name));
   // The product name belongs to this driver's immediate provider, not an arbitrary volume.
   io_registry_entry_t parent=0;if(IORegistryEntryGetParentEntry(obj,kIOServicePlane,&parent)==KERN_SUCCESS){CFTypeRef product=IORegistryEntrySearchCFProperty(parent,kIOServicePlane,CFSTR("Product Name"),kCFAllocatorDefault,0);if(product){if(CFGetTypeID(product)==CFStringGetTypeID())CFStringGetCString(product,o->name,sizeof(o->name),kCFStringEncodingUTF8);CFRelease(product);}IOObjectRelease(parent);}
   io_registry_entry_t media=0;
   if(IORegistryEntryGetChildEntry(obj,kIOServicePlane,&media)==KERN_SUCCESS){io_name_t mediaName;if(IORegistryEntryGetName(media,mediaName)==KERN_SUCCESS)strlcpy(o->name,mediaName,sizeof(o->name));IOObjectRelease(media);}
   CFTypeRef stats=IORegistryEntryCreateCFProperty(obj,CFSTR("Statistics"),kCFAllocatorDefault,0);
   if(stats){if(CFGetTypeID(stats)==CFDictionaryGetTypeID())o->ok=number(stats,CFSTR("Bytes (Read)"),&o->read_bytes)&&number(stats,CFSTR("Bytes (Write)"),&o->write_bytes);CFRelease(stats);}
  }IOObjectRelease(obj);
 }IOObjectRelease(it);return n;
}
uint32_t os_uid(void){return getuid();}
int32_t os_self(void){return getpid();}
int os_signal(int32_t pid,int force){if(pid<=1)return EINVAL;return kill(pid,force?SIGKILL:SIGTERM)==0?0:errno;}

#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <libkern/OSByteOrder.h>
static int smart_status(IOReturn status){
 if(status==kIOReturnNotPrivileged || status==kIOReturnNotPermitted)return 2;
 if(status==kIOReturnUnsupported)return 1;
 return 3;
}
int os_nvme_temperature(uint64_t driver_id,uint32_t *kelvin){
 *kelvin=0;
 io_registry_entry_t service=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching(driver_id));
 if(!service)return 3;
 int capable=0;
 for(int depth=0;depth<12;depth++){
  CFTypeRef value=IORegistryEntryCreateCFProperty(service,CFSTR(kIOPropertyNVMeSMARTCapableKey),kCFAllocatorDefault,0);
  if(value){capable=CFGetTypeID(value)==CFBooleanGetTypeID()&&CFBooleanGetValue(value);CFRelease(value);}
  if(capable)break;
  io_registry_entry_t parent=0;IOReturn result=IORegistryEntryGetParentEntry(service,kIOServicePlane,&parent);IOObjectRelease(service);service=parent;
  if(result!=KERN_SUCCESS||!service)return 1;
 }
 if(!capable){IOObjectRelease(service);return 1;}
 IOCFPlugInInterface **plugin=NULL;SInt32 score=0;
 IOReturn result=IOCreatePlugInInterfaceForService(service,kIONVMeSMARTUserClientTypeID,kIOCFPlugInInterfaceID,&plugin,&score);
 IOObjectRelease(service);
 if(result!=kIOReturnSuccess||!plugin)return smart_status(result);
 IONVMeSMARTInterface **smart=NULL;
 HRESULT query=(*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),(LPVOID*)&smart);
 if(query!=S_OK||!smart){IODestroyPlugInInterface(plugin);return 1;}
 NVMeSMARTData data={0};result=(*smart)->SMARTReadData(smart,&data);
 if(result==kIOReturnSuccess){uint16_t raw;memcpy(&raw,&data.TEMPERATURE,sizeof(raw));*kelvin=OSSwapLittleToHostInt16(raw);}
 (*smart)->Release(smart);IODestroyPlugInInterface(plugin);
 return result==kIOReturnSuccess?0:smart_status(result);
}

#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <arpa/inet.h>
static int exposed_address(const struct in_sockinfo *s){
 if(s->insi_vflag&INI_IPV4){uint32_t a=ntohl(s->insi_laddr.ina_46.i46a_addr4.s_addr);return (a>>24)!=127;}
 const struct in6_addr *a=&s->insi_laddr.ina_6;
 if(IN6_IS_ADDR_LOOPBACK(a))return 0;
 if(IN6_IS_ADDR_V4MAPPED(a))return a->s6_addr[12]!=127;
 return 1;
}
int os_ports(int32_t pid,CSPort *out,int cap){
 int size=proc_pidinfo(pid,PROC_PIDLISTFDS,0,NULL,0);if(size<=0)return -1;
 size+=32*PROC_PIDLISTFD_SIZE; // descriptors may be opened between both calls
 struct proc_fdinfo *fds=malloc((size_t)size);if(!fds)return -1;
 size=proc_pidinfo(pid,PROC_PIDLISTFDS,0,fds,size);if(size<=0){free(fds);return -1;}
 int n=0,count=size/(int)PROC_PIDLISTFD_SIZE;
 for(int i=0;i<count&&n<cap;i++){
  if(fds[i].proc_fdtype!=PROX_FDTYPE_SOCKET)continue;
  struct socket_fdinfo si;
  if(proc_pidfdinfo(pid,fds[i].proc_fd,PROC_PIDFDSOCKETINFO,&si,sizeof(si))!=sizeof(si))continue;
  if(si.psi.soi_kind!=SOCKINFO_TCP||si.psi.soi_proto.pri_tcp.tcpsi_state!=TSI_S_LISTEN)continue;
  const struct in_sockinfo *in=&si.psi.soi_proto.pri_tcp.tcpsi_ini;
  uint16_t port=ntohs((uint16_t)in->insi_lport);int exposed=exposed_address(in),dup=0;
  for(int j=0;j<n;j++)if(out[j].port==port){out[j].exposed|=exposed;dup=1;break;}
  if(!dup&&port){out[n].port=port;out[n].exposed=(uint8_t)exposed;n++;}
 }
 free(fds);return n;
}
int os_cwd(int32_t pid,char *out,int cap){
 struct proc_vnodepathinfo v;out[0]=0;
 if(proc_pidinfo(pid,PROC_PIDVNODEPATHINFO,0,&v,sizeof(v))!=sizeof(v))return -1;
 strlcpy(out,v.pvi_cdir.vip_path,(size_t)cap);return 0;
}
int os_network(uint64_t *in_bytes,uint64_t *out_bytes){
 *in_bytes=0;*out_bytes=0;int mib[6]={CTL_NET,PF_ROUTE,0,0,NET_RT_IFLIST2,0};size_t len=0;
 if(sysctl(mib,6,NULL,&len,NULL,0)<0)return -1;
 char *buf=malloc(len);if(!buf)return -1;
 if(sysctl(mib,6,buf,&len,NULL,0)<0){free(buf);return -1;}
 for(char *p=buf;p<buf+len;){
  struct if_msghdr *h=(struct if_msghdr*)p;if(h->ifm_msglen==0)break;
  if(h->ifm_type==RTM_IFINFO2){struct if_msghdr2 *h2=(struct if_msghdr2*)p;
   if(!(h2->ifm_flags&IFF_LOOPBACK)){*in_bytes+=h2->ifm_data.ifi_ibytes;*out_bytes+=h2->ifm_data.ifi_obytes;}}
  p+=h->ifm_msglen;
 }
 free(buf);return 0;
}

static int cf_int(CFDictionaryRef d,CFStringRef key,int fallback){
 CFNumberRef n=CFDictionaryGetValue(d,key);int v=fallback;if(n&&CFGetTypeID(n)==CFNumberGetTypeID())CFNumberGetValue(n,kCFNumberIntType,&v);return v;}
int os_battery(int32_t *percent,int32_t *charging,int32_t *on_ac,int32_t *minutes){
 CFTypeRef info=IOPSCopyPowerSourcesInfo();if(!info)return 1;
 CFArrayRef list=IOPSCopyPowerSourcesList(info);int missing=1;
 for(CFIndex i=0;list&&missing&&i<CFArrayGetCount(list);i++){
  CFDictionaryRef d=IOPSGetPowerSourceDescription(info,CFArrayGetValueAtIndex(list,i));if(!d)continue;
  CFStringRef type=CFDictionaryGetValue(d,CFSTR(kIOPSTypeKey));
  if(!type||CFStringCompare(type,CFSTR(kIOPSInternalBatteryType),0)!=kCFCompareEqualTo)continue;
  int cur=cf_int(d,CFSTR(kIOPSCurrentCapacityKey),0),max=cf_int(d,CFSTR(kIOPSMaxCapacityKey),100);
  CFBooleanRef ch=CFDictionaryGetValue(d,CFSTR(kIOPSIsChargingKey));
  CFStringRef state=CFDictionaryGetValue(d,CFSTR(kIOPSPowerSourceStateKey));
  *percent=max>0?cur*100/max:cur;*charging=ch&&CFBooleanGetValue(ch);
  *on_ac=state&&CFStringCompare(state,CFSTR(kIOPSACPowerValue),0)==kCFCompareEqualTo;
  *minutes=*charging?cf_int(d,CFSTR(kIOPSTimeToFullChargeKey),-1):*on_ac?-1:cf_int(d,CFSTR(kIOPSTimeToEmptyKey),-1);
  missing=0;}
 if(list)CFRelease(list);CFRelease(info);return missing;}

int32_t os_pressure_level(void){
 int level=0;size_t size=sizeof(level);
 return sysctlbyname("kern.memorystatus_vm_pressure_level",&level,&size,NULL,0)==0?level:-1;}

// Darwin background QoS for a same-user process: lower CPU and I/O priority, reversible.
int os_background(int32_t pid,int on){
 errno=0;return setpriority(PRIO_DARWIN_PROCESS,pid,on?PRIO_DARWIN_BG:0)==0?0:errno;}

int64_t os_local_time(int64_t day,int hour,int minute){
 time_t t=(time_t)day;struct tm tm;if(!localtime_r(&t,&tm))return -1;
 tm.tm_hour=hour;tm.tm_min=minute;tm.tm_sec=0;tm.tm_isdst=-1;
 time_t out=mktime(&tm);return out==(time_t)-1?-1:(int64_t)out;}

int os_local_format(int64_t t,char *out,int size){
 time_t v=(time_t)t;struct tm tm;
 if(size<17||!localtime_r(&v,&tm))return -1;
 return strftime(out,(size_t)size,"%Y-%m-%d %H:%M",&tm)>0?0:-1;}
