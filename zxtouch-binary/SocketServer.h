#ifndef ZXTOUCHD_SOCKET_SERVER_H
#define ZXTOUCHD_SOCKET_SERVER_H

#import <Foundation/Foundation.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

#define ZXTOUCHD_PORT 6001
#define ZXTOUCHD_ADDR "0.0.0.0"

void socketServer();

#endif
