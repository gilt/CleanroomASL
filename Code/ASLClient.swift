//
//  ASLClient.swift
//  Cleanroom Project
//
//  Created by Evan Maloney on 3/17/15.
//  Copyright (c) 2015 Gilt Groupe. All rights reserved.
//

import CleanroomBase

/**
`ASLClient` instances maintain a client connection to the ASL daemon, and can
used to perform logging and to perform log search queries.

**Note:** Because the underlying client connection is not intended to be shared
across threads, each `ASLClient` has an associated GCD serial queue used to
ensure that the underlying ASL client connection is only ever used from a single
thread.
*/
public class ASLClient
{
    /**
    Represents ASL client creation option values, which are used to determine
    the behavior of an `ASLClient`. These are bit-flag values that can be
    combined and otherwise manipulated with bitwise operators.
    */
    public struct Options: RawOptionSetType, BooleanType
    {
        /** The raw `UInt32` value representing the receiver's bit flags. */
        public var rawValue: UInt32 { return value }

        /** Indicates whether the receiver has at least one bit flag set;
        `true` if it does; `false` if not. */
        public var boolValue: Bool { return value != 0 }

        private var value: UInt32

        /**
        Initializes a new `ASLClient.Options` value with the specified
        raw value.
        
        :param:     rawValue A `UInt32` value containing the raw bit flag
                    values to use.
        */
        public init(_ rawValue: UInt32) { value = rawValue }

        /**
        Initializes a new `ASLClient.Options` value with the specified
        raw value.
        
        :param:     rawValue A `UInt32` value containing the raw bit flag
                    values to use.
        */
        public init(rawValue: UInt32) { value = rawValue }

        /**
        Initializes a new `ASLClient.Options` value with a `nil` literal,
        which would be the equivalent of the `.None` value.
        */
        public init(nilLiteral: ()) { value = 0 }

        /** An `ASLClient.Options` value wherein none of the bit flags are
        set. */
        public static var allZeros: Options   { return self(0) }

        /** An `ASLClient.Options` value wherein none of the bit flags are
        set. Equivalent to `allZeros`. */
        public static var None: Options       { return self(0) }

        /** An `ASLClient.Options` value with the `ASL_OPT_STDERR` flag set. */
        public static var StdErr: Options     { return self(0x00000001) }

        /** An `ASLClient.Options` value with the `ASL_OPT_NO_DELAY` flag 
        set. */
        public static var NoDelay: Options    { return self(0x00000002) }

        /** An `ASLClient.Options` value with the `ASL_OPT_NO_REMOTE`
        flag set. */
        public static var NoRemote: Options   { return self(0x00000004) }
    }

    /** The string that will be used by ASL the *sender* of any log messages
    passed to the receiver's `log()` function. */
    public let sender: String?

    /** The string that will be used by ASL the *facility* of any log messages
    passed to the receiver's `log()` function. */
    public let facility: String?

    public let filterMask: Int32

    /** If `true`, the receiver is mirroring log entries in raw form to 
    the standard error stream; `false` otherwise. */
    public let useRawStdErr: Bool

    /** The `ASLClient.Options` value that determines the behavior of ASL. */
    public let options: Options

    /** The GCD queue used to serialize log operations. This is exposed to
    allow low-level ASL operations not supported by `ASLClient` to be 
    performed using the underlying `aslclient`. This queue must be used for all
    ASL operations using the receiver's `client` property. */
    public let queue: dispatch_queue_t

    /** Determines whether the receiver's connection to the ASL  */
    public var isOpen: Bool { return client != nil }

    private var client: aslclient?

    /**
    Initializes a new `ASLClient` instance.
    
    :param:     sender Will be used as the `ASLMessageKey` value for the
                `.Sender` key for all log messages sent to ASL. If `nil`, ASL
                will use the process name.
    
    :param:     facility Will be used as the `ASLMessageKey` value for the
                `.Facility` key for all log messages sent to ASL. If `nil`, ASL
                will select a default.
    
    :param:     filterMask Specifies the priority filter that should be applied
                to messages sent to the log.
    
    :param:     useRawStdErr If `true`, messages sent through the `ASLClient`
                will be mirrored to standard error without modification.
                Note that this differs from the behavior of the `.StdErr`
                value for the `ASLClient.Options` parameter, which performs
                some escaping and may add additional text to the message.

    :param:     options An `ASLClient.Options` value specifying the client
                options to be used by this new client. Note that if the
                `.StdErr` value is passed and `rawStdErr` is also `true`,
                the behavior of `rawStdErr` will be used, overriding the
                `.StdErr` behavior.
    */
    public init(sender: String? = nil, facility: String? = nil, filterMask: Int32 = ASLPriorityLevel.Debug.filterMaskUpTo, useRawStdErr: Bool = true, options: Options = .NoRemote)
    {
        self.sender = sender
        self.facility = facility
        self.filterMask = filterMask
        self.useRawStdErr = useRawStdErr
        self.options = options
        self.queue = dispatch_queue_create("ASLClient.\(sender)", DISPATCH_QUEUE_SERIAL)
    }

    deinit {
        if let c = client {
            dispatch_sync(queue) {
                asl_close(c)
            }
        }
    }

    public func open()
    {
        if client == nil {
            dispatch_sync(queue) {
                var options = self.options.rawValue
                if self.useRawStdErr {
                    options &= ~Options.StdErr.rawValue
                }

                self.client = asl_open(self.sender ?? nil, self.facility ?? nil, options)

                asl_set_filter(self.client!, self.filterMask)

                if self.useRawStdErr {
                    asl_add_output_file(self.client!, 2, ASL_MSG_FMT_MSG, ASL_TIME_FMT_LCL, self.filterMask, ASL_ENCODE_NONE)
                }
            }
        }
    }

    public func close()
    {
        if let c = client {
            dispatch_sync(queue) {
                asl_close(c)
                self.client = nil
            }
        }
    }

    private func acquireClient()
        -> aslclient
    {
        if !isOpen {
            open()
        }
        return client!
    }

    private func dispatcher(synchronously: Bool = false)(block: dispatch_block_t)
    {
        if synchronously {
            return dispatch_sync(queue, block)
        } else {
            return dispatch_async(queue, block)
        }
    }

    public func log(message: ASLMessageObject, logSynchronously: Bool = false)
    {
        let dispatch = dispatcher(synchronously: logSynchronously)
        dispatch {
            asl_send(self.acquireClient(), message.aslObject)
        }
    }

    /**
    Asynchronously reads the ASL log, issuing one call to the callback function
    for each relevant entry in the log.

    Only entries that have a valid timestamp and message will be provided to
    the callback.

    :param:     query The `ASLQueryObject` representing the search query to run.

    :param:     callback The callback function to be invoked for each log entry.
                Make no assumptions about which thread will be calling the
                function.
    */
    public func search(query: ASLQueryObject, callback: ASLQueryObject.ResultCallback)
    {
        let dispatch = dispatcher()
        dispatch {
            let results = asl_search(self.acquireClient(), query.aslObject)

            var keepGoing = true
            var record = asl_next(results)
            while record != nil && keepGoing {
                if let message = record[.Message] {

                    println(record[.Sender])

                    if let timestampStr = record[.Time] {
                        if let timestampInt = timestampStr.toInt() {
                            var timestamp = NSTimeInterval(timestampInt)

                            if let nanoStr = record[.TimeNanoSec] {
                                if let nanoInt = nanoStr.toInt() {
                                    let nanos = Double(nanoInt) / Double(NSEC_PER_SEC)
                                    timestamp += nanos
                                }
                            }

                            let logEntryTime = NSDate(timeIntervalSince1970: timestamp)

                            var priority = ASLPriorityLevel.Notice
                            if let logLevelStr = record[.Level],
                                let logLevelInt = logLevelStr.toInt(),
                                let level = ASLPriorityLevel(rawValue: Int32(logLevelInt))
                            {
                                priority = level
                            }

                            let record = ASLQueryObject.ResultRecord(client: self, query: query, priority: priority, message: message, timestamp: logEntryTime)
                            keepGoing = callback(record)
                        }
                    }
                }
                record = asl_next(results)
            }

            if keepGoing {
                callback(nil)
            }

            asl_release(results)
        }
    }
}