// Connect only to the two parent-owned loopback listeners. Never send data or use an Internet address.
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
int main(int argc, char **argv) {
    if (argc != 4) return 10;
    struct sockaddr_in a4 = {0}; a4.sin_family=AF_INET; a4.sin_port=htons((unsigned short)atoi(argv[2])); inet_pton(AF_INET,"127.0.0.1",&a4.sin_addr);
    struct sockaddr_in6 a6 = {0}; a6.sin6_family=AF_INET6; a6.sin6_port=htons((unsigned short)atoi(argv[3])); inet_pton(AF_INET6,"::1",&a6.sin6_addr);
    int fd4=socket(AF_INET,SOCK_STREAM,0), e4=errno, r4=-1;
    if (fd4>=0) { r4=connect(fd4,(struct sockaddr*)&a4,sizeof(a4));e4=errno;close(fd4); }
    int fd6=socket(AF_INET6,SOCK_STREAM,0), e6=errno, r6=-1;
    if (fd6>=0) { r6=connect(fd6,(struct sockaddr*)&a6,sizeof(a6));e6=errno;close(fd6); }
    int blocked4=r4<0 && (e4==EPERM || e4==EACCES);
    int blocked6=r6<0 && (e6==EPERM || e6==EACCES);
    int outside=open(argv[1],O_RDONLY|O_NOFOLLOW);
    int blockedRead=outside<0 && (errno==EPERM || errno==EACCES);
    if(outside>=0)close(outside);
    printf("IPv4 connection denied=%d(errno=%d); IPv6 connection denied=%d(errno=%d); outside dummy read denied=%d; document bytes sent=0\n",blocked4,e4,blocked6,e6,blockedRead);
    return blocked4 && blocked6 && blockedRead ? 0:1;
}
