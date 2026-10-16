// Read-only sampler. It never sends a signal or reads arguments/environment.
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
static double clock_s(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
int main(int argc,char**argv){
 if(argc!=3){fprintf(stderr,"usage: measure PID seconds\n");return 2;}
 int pid=atoi(argv[1]),seconds=atoi(argv[2]);if(pid<=1||seconds<1||seconds>300)return 2;
 struct rusage_info_v4 first={0},last={0};
 if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t*)&first)){perror("proc_pid_rusage");return 1;}
 double start=clock_s();uint64_t max=first.ri_phys_footprint;int n=0;double sum=0;
 for(int i=0;i<seconds;i++){sleep(1);if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t*)&last)){perror("proc_pid_rusage");return 1;}if(last.ri_proc_start_abstime!=first.ri_proc_start_abstime){fprintf(stderr,"PID identity changed\n");return 1;}if(last.ri_phys_footprint>max)max=last.ri_phys_footprint;sum+=last.ri_phys_footprint;n++;}
 double elapsed=clock_s()-start;mach_timebase_info_data_t tb;mach_timebase_info(&tb);
 printf("{\"pid\":%d,\"seconds\":%.3f,\"cpu_one_core_percent\":%.4f,\"footprint_mean_mib\":%.3f,\"footprint_peak_mib\":%.3f,\"rss_last_mib\":%.3f,\"package_idle_wakeups_per_second\":%.4f,\"interrupt_wakeups_per_second\":%.4f,\"energy\":\"unavailable: raw billed_energy units not interpreted\"}\n",pid,elapsed,((last.ri_user_time-first.ri_user_time)+(last.ri_system_time-first.ri_system_time))*((double)tb.numer/tb.denom)/1e9/elapsed*100,sum/n/1048576.,max/1048576.,last.ri_resident_size/1048576.,(last.ri_pkg_idle_wkups-first.ri_pkg_idle_wkups)/elapsed,(last.ri_interrupt_wkups-first.ri_interrupt_wkups)/elapsed);
}
