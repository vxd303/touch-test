#include "Task.h"
#include "Touch.h"
#include "Process.h"
#include "AlertBox.h"
#include "Record.h"
#include "Play.h"
#include "SocketServer.h"
#include "Toast.h"
#include "UIKeyboard.h"
#include "DeviceInfo.h"
#include "TouchIndicator/TouchIndicatorWindow.h"
#include "HardwareKey.h"
#include "Scheduler.h"
#include "RuntimeUtils.h"
#import <mach/mach.h>
#include <Foundation/NSDistributedNotificationCenter.h>
#include "UpdateCache.h"
#include "Screen.h"
#include "NSTask.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

extern CFRunLoopRef recordRunLoop;

static void forwardTaskToDaemon(UInt8 *buff, CFWriteStreamRef writeStreamRef)
{
    if (!buff || !writeStreamRef) {
        return;
    }
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        notifyClient((UInt8 *)"1;;daemon_socket_error\r\n", writeStreamRef);
        return;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(6000);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(sock);
        notifyClient((UInt8 *)"1;;daemon_connect_failed\r\n", writeStreamRef);
        return;
    }
    struct timeval timeout;
    timeout.tv_sec = 30;
    timeout.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    NSMutableData *payload = [NSMutableData dataWithBytes:buff length:strlen((char *)buff)];
    const char *newline = "\r\n";
    [payload appendBytes:newline length:strlen(newline)];
    send(sock, payload.bytes, payload.length, 0);
    NSMutableData *responseData = [NSMutableData data];
    char responseBuffer[512];
    bool sawLineEnding = false;
    while (!sawLineEnding) {
        memset(responseBuffer, 0, sizeof(responseBuffer));
        ssize_t readSize = recv(sock, responseBuffer, sizeof(responseBuffer) - 1, 0);
        if (readSize <= 0) {
            break;
        }
        [responseData appendBytes:responseBuffer length:(NSUInteger)readSize];
        if (memmem(responseBuffer, (size_t)readSize, "\r\n", 2) != NULL) {
            sawLineEnding = true;
        }
        if ([responseData length] > 8192) {
            break;
        }
    }
    close(sock);
    if ([responseData length] > 0) {
        notifyClient((UInt8 *)responseData.bytes, writeStreamRef);
    } else {
        notifyClient((UInt8 *)"1;;daemon_no_response\r\n", writeStreamRef);
    }
}

/*
get task type
*/
static int getTaskType(UInt8* dataArray)
{
	int taskType = 0;
	for (int i = 0; i <= 1; i++)
	{
		taskType += (dataArray[i] - '0')*pow(10, 1-i);
	}
	return taskType;
}

/**
Process Task
*/
void processTask(UInt8 *buff, CFWriteStreamRef writeStreamRef)
{
    //NSLog(@"### com.zjx.springboard: task type: %d. Data: %s", getTaskType(buff), buff);
    UInt8 *eventData = buff + 0x2;
    int taskType = getTaskType(buff);

    //for touching
    if (taskType == TASK_PERFORM_TOUCH)
    {
        @autoreleasepool{
            performTouchFromRawData(eventData);
        }
    }
    else if (taskType == TASK_PROCESS_BRING_FOREGROUND) //bring to foreground
    {
        @autoreleasepool{   
            switchProcessForegroundFromRawData(eventData);
            notifyClient((UInt8*)"0\r\n", writeStreamRef); 
        }
    }
    else if (taskType == TASK_SHOW_ALERT_BOX)
    {
        @autoreleasepool{   
            NSError *err = nil;
            showAlertBoxFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_USLEEP)
    {
        if (writeStreamRef)
        {
            int usleepTime = 0;
            @try{
                usleepTime = atoi((char*)eventData);
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
                return;
            }
            //NSLog(@"com.zjx.springboard: sleep %d microseconds", usleepTime);
            usleep(usleepTime);
            notifyClient((UInt8*)"0;;Sleep ends\r\n", writeStreamRef); 
        }
        else
        {
            int usleepTime = 0;

            @try{
                usleepTime = atoi((char*)eventData);
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
                return;
            }
            //NSLog(@"com.zjx.springboard: sleep %d microseconds", usleepTime);
            usleep(usleepTime);
        }

    }
    else if (taskType == TASK_RUN_SHELL)
    {
        @autoreleasepool{
            NSTask *task = [[NSTask alloc] init];

            // 设置执行的命令和参数
            [task setLaunchPath:@"/usr/bin/sudo"];
            [task setArguments:@[[NSString stringWithFormat:@"sudo zxtouchb -e \"%s\"", eventData]]];

            // 设置输出管道，如果需要获取命令的输出
            NSPipe *pipe = [NSPipe pipe];
            [task setStandardOutput:pipe];

            // 启动任务
            [task launch];

            // 等待任务完成
            [task waitUntilExit];

            // 如果需要获取命令的输出，可以使用以下代码
            NSFileHandle *fileHandle = [pipe fileHandleForReading];
            NSData *data = [fileHandle readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSLog(@"Command Output:\n%@", output);

//            system([[NSString stringWithFormat:@"sudo zxtouchb -e \"%s\"", eventData] UTF8String]);
            notifyClient((UInt8*)"0\r\n", writeStreamRef);
        }
    }
    else if (taskType == TASK_TOUCH_RECORDING_START)
    {
        @autoreleasepool {
            NSError *err = nil;
            startRecording(writeStreamRef, &err);    
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_RECORDING_STOP)
    {
        @autoreleasepool {
            stopRecording(); 
            notifyClient((UInt8*)"0\r\n", writeStreamRef); 
        }
    }
    else if (taskType == TASK_PLAY_SCRIPT)
    {
        @autoreleasepool {
            NSError *err = nil;
            playScript((UInt8*)eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_PLAY_SCRIPT_FORCE_STOP)
    {
        @autoreleasepool {
            NSError *err = nil;
            stopScriptPlaying(&err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEMPLATE_MATCH)
    {
        // Refactored: template matching now runs inside zxtouchd to reduce SpringBoard RAM/CPU usage.
        forwardTaskToDaemon(buff, writeStreamRef);
    }
    else if (taskType == TASK_SHOW_TOAST)
    {
        @autoreleasepool {
            NSError *err = nil;
            showToastFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_COLOR_PICKER)
    {
        // Refactored: color picking now runs inside zxtouchd to reduce SpringBoard RAM/CPU usage.
        forwardTaskToDaemon(buff, writeStreamRef);
    }
    else if (taskType == TASK_TEXT_INPUT)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = inputTextFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_GET_DEVICE_INFO)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *deviceInfo = getDeviceInfoFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", deviceInfo] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_INDICATOR)
    {
        @autoreleasepool {
            NSError *err = nil;
            handleTouchIndicatorTaskWithRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEXT_RECOGNIZER)
    {
        // Refactored: OCR now runs inside zxtouchd to reduce SpringBoard RAM/CPU usage.
        forwardTaskToDaemon(buff, writeStreamRef);
    }
    else if (taskType == TASK_COLOR_SEARCHER)
    {
        // Refactored: color searching now runs inside zxtouchd to reduce SpringBoard RAM/CPU usage.
        forwardTaskToDaemon(buff, writeStreamRef);
    }
    else if (taskType == TASK_HARDWARE_KEY)
    {
        @autoreleasepool {
            NSError *err = nil;
            sendHardwareKeyEventFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_APP_KILL)
    {
        @autoreleasepool {
            NSError *err = nil;
            killAppFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_APP_STATE)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *state = appStateFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", state] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_APP_INFO)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *info = appInfoFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", info] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_FRONTMOST_APP_ID)
    {
        @autoreleasepool {
            NSString *frontApp = frontMostAppId();
            notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", frontApp] UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_FRONTMOST_APP_ORIENTATION)
    {
        @autoreleasepool {
            NSString *orientation = frontMostAppOrientation();
            notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", orientation] UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_SET_AUTO_LAUNCH)
    {
        @autoreleasepool {
            NSError *err = nil;
            setAutoLaunchFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_LIST_AUTO_LAUNCH)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *list = listAutoLaunch(&err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", list ?: @""] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_SET_TIMER)
    {
        @autoreleasepool {
            NSError *err = nil;
            setTimerFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_REMOVE_TIMER)
    {
        @autoreleasepool {
            NSError *err = nil;
            removeTimerFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_KEEP_AWAKE)
    {
        @autoreleasepool {
            NSError *err = nil;
            keepAwakeFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_STOP_SCRIPT)
    {
        @autoreleasepool {
            NSError *err = nil;
            stopScriptFromRawData(&err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_DIALOG)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *response = dialogFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", response ?: @""] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_CLEAR_DIALOG)
    {
        @autoreleasepool {
            NSError *err = nil;
            clearDialogValues(&err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_ROOT_DIR)
    {
        @autoreleasepool {
            NSString *path = rootDirValue();
            notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", path] UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_CURRENT_DIR)
    {
        @autoreleasepool {
            NSString *path = currentDirValue();
            notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", path] UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_BOT_PATH)
    {
        @autoreleasepool {
            NSString *path = botPathValue();
            notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", path] UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_SCREENSHOT)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *resultPath = handleScreenshotTaskFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else if (resultPath)
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", resultPath] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_UPDATE_CACHE)
    {
        @autoreleasepool{
            NSError *err = nil;
            updateCacheFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[@"0\r\n" UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEST)
    {

    }
}
