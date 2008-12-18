/*
 * Author: Landon Fuller <landonf@plausiblelabs.com>
 *
 * Copyright (c) 2008 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 */

#import "GTMSenTestCase.h"

#import "PLCrashLog.h"
#import "PLCrashLogWriter.h"
#import "PLCrashFrameWalker.h"

#import <sys/stat.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <sys/utsname.h>

#import "crash_report.pb-c.h"

@interface PLCrashLogWriterTests : SenTestCase {
@private
    /* Path to crash log */
    NSString *_logPath;
    
    /* Test thread */
    plframe_test_thead_t _thr_args;
}

@end


@implementation PLCrashLogWriterTests

- (void) setUp {
    /* Create a temporary log path */
    _logPath = [[NSTemporaryDirectory() stringByAppendingString: [[NSProcessInfo processInfo] globallyUniqueString]] retain];
    
    /* Create the test thread */
    plframe_test_thread_spawn(&_thr_args);
}

- (void) tearDown {
    NSError *error;
    
    /* Delete the file */
    STAssertTrue([[NSFileManager defaultManager] removeItemAtPath: _logPath error: &error], @"Could not remove log file");
    [_logPath release];

    /* Stop the test thread */
    plframe_test_thread_stop(&_thr_args);
}

// check a crash report's system info
- (void) checkSystemInfo: (Plcrash__CrashReport *) crashReport {
    Plcrash__CrashReport__SystemInfo *systemInfo = crashReport->system_info;
    struct utsname uts;
    uname(&uts);

    STAssertNotNULL(systemInfo, @"No system info available");
    // Nothing else to do?
    if (systemInfo == NULL)
        return;

    STAssertEquals(systemInfo->operating_system, PLCrashLogHostOperatingSystem, @"Unexpected OS value");
    
    STAssertNotNULL(systemInfo->os_version, @"No OS version encoded");

    STAssertEquals(systemInfo->architecture, PLCrashLogHostArchitecture, @"Unexpected machine type");

    STAssertTrue(systemInfo->timestamp != 0, @"Timestamp uninitialized");
}

// check a crash report's app info
- (void) checkAppInfo: (Plcrash__CrashReport *) crashReport {
    Plcrash__CrashReport__ApplicationInfo *appInfo = crashReport->application_info;
    
    STAssertNotNULL(appInfo, @"No app info available");
    // Nothing else to do?
    if (appInfo == NULL)
        return;

    STAssertTrue(strcmp(appInfo->identifier, "test.id") == 0, @"Incorrect app ID written");
    STAssertTrue(strcmp(appInfo->version, "1.0") == 0, @"Incorrect app version written");
}


- (void) checkThreads: (Plcrash__CrashReport *) crashReport {
    Plcrash__CrashReport__Thread **threads = crashReport->threads;
    BOOL foundCrashed = NO;

    STAssertNotNULL(threads, @"No thread messages were written");
    STAssertTrue(crashReport->n_threads > 0, @"0 thread messages were written");

    for (int i = 0; i < crashReport->n_threads; i++) {
        Plcrash__CrashReport__Thread *thread = threads[i];

        /* Check that the threads are provided in order */
        STAssertEquals((uint32_t)i, thread->thread_number, @"Threads were encoded out of order (%d vs %d)", i, thread->thread_number);

        /* Check that there is at least one frame */
        STAssertNotEquals((size_t)0, thread->n_frames, @"No frames available in backtrace");
        
        /* Check for crashed thread */
        if (thread->crashed) {
            foundCrashed = YES;
            STAssertNotEquals((size_t)0, thread->n_registers, @"No registers available on crashed thread");
        }
        
        for (int j = 0; j < thread->n_frames; j++) {
            Plcrash__CrashReport__Thread__StackFrame *f = thread->frames[j];
            STAssertNotEquals((uint64_t)0, f->pc, @"Backtrace includes NULL pc");
        }
    }

    STAssertTrue(foundCrashed, @"No crashed thread was provided");
}

- (void) checkBinaryImages: (Plcrash__CrashReport *) crashReport {
    Plcrash__CrashReport__BinaryImage **images = crashReport->binary_images;

    STAssertNotNULL(images, @"No image messages were written");
    STAssertTrue(crashReport->n_binary_images, @"0 thread messages were written");

    for (int i = 0; i < crashReport->n_binary_images; i++) {
        Plcrash__CrashReport__BinaryImage *image = images[i];
        
        STAssertNotNULL(image->name, @"Null image name");
        STAssertTrue(image->name[0] == '/', @"Image is not absolute path");
    }
}

- (void) checkException: (Plcrash__CrashReport *) crashReport {
    Plcrash__CrashReport__Exception *exception = crashReport->exception;
    
    STAssertNotNULL(exception, @"No exception was written");
    STAssertTrue(strcmp(exception->name, "TestException") == 0, @"Exception name was not correctly serialized");
    STAssertTrue(strcmp(exception->reason, "TestReason") == 0, @"Exception reason was not correctly serialized");
}


- (void) testWriteReport {
    siginfo_t info;
    plframe_cursor_t cursor;
    plcrash_log_writer_t writer;
    plcrash_async_file_t file;

    /* Initialze faux crash data */
    {
        info.si_addr = 0x0;
        info.si_errno = 0;
        info.si_pid = getpid();
        info.si_uid = getuid();
        info.si_code = SEGV_MAPERR;
        info.si_signo = SIGSEGV;
        info.si_status = 0;
        
        /* Steal the test thread's stack for iteration */
        plframe_cursor_thread_init(&cursor, pthread_mach_thread_np(_thr_args.thread));
    }

    /* Open the output file */
    int fd = open([_logPath UTF8String], O_RDWR|O_CREAT|O_EXCL, 0644);
    plcrash_async_file_init(&file, fd, 0);

    /* Initialize a writer */
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_log_writer_init(&writer, @"test.id", @"1.0"), @"Initialization failed");

    /* Set an exception */
    plcrash_log_writer_set_exception(&writer, [NSException exceptionWithName: @"TestException" reason: @"TestReason" userInfo: nil]);

    /* Write the crash report */
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_log_writer_write(&writer, &file, &info, cursor.uap), @"Crash log failed");

    /* Close it */
    plcrash_log_writer_close(&writer);
    plcrash_log_writer_free(&writer);

    /* Flush the output */
    plcrash_async_file_flush(&file);

    /* Try reading it back in */
    void *buf;
    struct stat statbuf;
    {
        STAssertEquals(0, stat([_logPath UTF8String], &statbuf), @"fstat failed");
        
        buf = mmap(NULL, statbuf.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        STAssertNotNULL(buf, @"Could not map pages");
    }

    /* Check the file magic. The file must be large enough for the value + version + data */
    struct PLCrashLogFileHeader *header = buf;
    STAssertTrue(statbuf.st_size > sizeof(struct PLCrashLogFileHeader), @"File is too small for magic + version + data");
    // verifies correct byte ordering of the file magic
    STAssertTrue(memcmp(header->magic, PLCRASH_LOG_FILE_MAGIC, strlen(PLCRASH_LOG_FILE_MAGIC)) == 0, @"File header is not 'plcrash', is: '%s'", (const char *) &header->magic);
    STAssertEquals(header->version, (uint8_t) PLCRASH_LOG_FILE_VERSION, @"File version is not equal to 0");

    /* Try to read the crash report */
    Plcrash__CrashReport *crashReport;
    crashReport = plcrash__crash_report__unpack(&protobuf_c_system_allocator, statbuf.st_size - sizeof(struct PLCrashLogFileHeader), header->data);
    
    /* If reading the report didn't fail, test the contents */
    STAssertNotNULL(crashReport, @"Could not decode crash report");
    if (crashReport != NULL) {
        /* Test the report */
        [self checkSystemInfo: crashReport];
        [self checkThreads: crashReport];
        [self checkException: crashReport];

        /* Check the signal info */
        STAssertTrue(strcmp(crashReport->signal->name, "SIGSEGV") == 0, @"Signal incorrect");
        STAssertTrue(strcmp(crashReport->signal->code, "SEGV_MAPERR") == 0, @"Signal code incorrect");

        /* Free it */
        protobuf_c_message_free_unpacked((ProtobufCMessage *) crashReport, &protobuf_c_system_allocator);
    }


    STAssertEquals(0, munmap(buf, statbuf.st_size), @"Could not unmap pages: %s", strerror(errno));

    plcrash_async_file_close(&file);
}

@end
