//
//  JavaScript execution context
//
import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#else
import CJSCore
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: JXContext

/// A JavaScript execution context. This is a cross-platform analogue to the Objective-C `JavaScriptCore.JSContext`.
///
/// The `JXContext` used the system's `JavaScriptCore` C interface on Apple platforms, and `webkitgtk-4.0` on Linux platforms. Windows is TBD.
///
/// This wraps a `JSGlobalContextRef`, and is the equivalent of `JavaScriptCore.JSContext`
@available(macOS 11, iOS 13, tvOS 13, *)
public final class JXContext {
    public let vm: JXVM
    public let context: JSGlobalContextRef
    public var exceptionHandler: ((JXContext?, JXValue?) -> Void)?

    /// Creates `JXContext` with the given `JXVM`.  `JXValue` references may be used interchangably with multiple instances of `JXContext` with the same `JXVM`, but sharing between  separate `JXVM`s will result in undefined behavior.
    public init(virtualMachine vm: JXVM = JXVM()) {
        self.vm = vm
        self.context = JSGlobalContextCreateInGroup(vm.group, nil)
    }

    /// Wraps an existing `JSGlobalContextRef` in a `JXContext`. Address space will be shared between both contexts.
    public init(env: JXContext) {
        self.vm = JXVM(group: JSContextGetGroup(env.context))
        self.context = env.context
        JSGlobalContextRetain(env.context)
    }

    deinit {
        JSGlobalContextRelease(context)
    }
}

@available(macOS 11, iOS 13, tvOS 13, *)
public final class JXValueError {
    public let value: JXValue
    public let msg: String?

    public init(value: JXValue) throws {
        self.value = value
        self.msg = value.description
    }
}

@available(macOS 11, iOS 13, tvOS 13, *)
public enum JXErrors : Error {
    /// An error thrown from the JS environment
    case jxerror(JXValue)
    /// A required resource was missing
    case missingResource(String)
    /// An evaluation error occurred
    case evaluationErrorString(String)
    /// An evaluation error occurred
    case evaluationError(JXValue)
    /// An evaluation error occurred
    case evaluationErrorUnknown
    /// The API call requires a higher system version (e.g., for JS typed array support)
    case minimumSystemVersion
    /// Unable to create a new promise
    case cannotCreatePromise
    case cannotCreateArrayBuffer
    case cannotLoadScriptURL(URL, URLResponse)
    case asyncEvalMustReturnPromise
    case invalidAsyncPromise
    case callOnNonFunction
    case propertyAccessNonObject
    case addToNonArray
}


@available(macOS 11, iOS 13, tvOS 13, *)
extension JXContext {

    /// Evaulates the JavaScript.
    @discardableResult public func eval(_ script: String, this: JXValue? = nil) throws -> JXValue {
        let script = script.withCString(JSStringCreateWithUTF8CString)
        defer { JSStringRelease(script) }

        var err: JSValueRef?
        let result = JSEvaluateScript(context, script, this?.value, nil, 0, &err)
        if let err = err {
            throw JXErrors.jxerror(JXValue(env: self, valueRef: err))
        }

        return result.map { JXValue(env: self, valueRef: $0) } ?? JXValue(undefinedIn: self)
    }

    /// Asynchronously evaulates the given script
    @discardableResult public func eval(_ script: String, method: Bool = true, this: JXValue? = nil, priority: TaskPriority) async throws -> JXValue {
        let promise = try eval(script, this: this)

        guard !promise.isFunction && !promise.isConstructor else { // should return a Promise, not a function
            throw JXErrors.asyncEvalMustReturnPromise
        }

        guard try promise.isObject && promise.stringValue == "[object Promise]" else {
            throw JXErrors.asyncEvalMustReturnPromise
        }

        let then = try promise["then"]
        guard then.isFunction else {
            throw JXErrors.invalidAsyncPromise
        }

        return try await withCheckedThrowingContinuation { [weak self] c in
            do {
                guard let self = self else {
                    return c.resume(throwing: JXErrors.cannotCreatePromise)
                }

                let fulfilled = JXValue(newFunctionIn: self) { ctx, this, args in
                    c.resume(returning: args.first ?? JXValue(undefinedIn: ctx))
                    return JXValue(undefinedIn: ctx)
                }

                let rejected = JXValue(newFunctionIn: self) { ctx, this, arg in
                    c.resume(throwing: arg.first.map(JXErrors.jxerror) ?? JXErrors.cannotCreatePromise)
                    return JXValue(undefinedIn: ctx)
                }

                let presult = try then.call(withArguments: [fulfilled, rejected], this: promise)

                // then() should return a promise as well
                if try !presult.isObject || presult.stringValue != "[object Promise]" {
                    // we can't throw here because it could complete the promise multiple times
                    throw JXErrors.asyncEvalMustReturnPromise
                }
            } catch {
                return c.resume(throwing: error)
            }
        }
    }

    /// Checks for syntax errors in a string of JavaScript.
    ///
    /// - Parameters:
    ///   - script: The script to check for syntax errors.
    ///   - sourceURL: A URL for the script's source file. This is only used when reporting exceptions. Pass `nil` to omit source file information in exceptions.
    ///   - startingLineNumber: An integer value specifying the script's starting line number in the file located at sourceURL. This is only used when reporting exceptions.
    ///
    /// - Returns: true if the script is syntactically correct; otherwise false.
    @inlinable public func check(_ script: String, sourceURL URLString: String? = nil, startingLineNumber: Int = 0) throws -> Bool {

        let script = script.withCString(JSStringCreateWithUTF8CString)
        defer { JSStringRelease(script) }

        let sourceURL = URLString?.withCString(JSStringCreateWithUTF8CString)
        defer { sourceURL.map(JSStringRelease) }

        return try throwing(env: self) {
            JSCheckScriptSyntax(context, script, sourceURL, Int32(startingLineNumber), $0)
        }
    }

    /// Performs a JavaScript garbage collection.
    ///
    /// During JavaScript execution, you are not required to call this function; the JavaScript engine will garbage collect as needed.
    /// JavaScript values created within a context group are automatically destroyed when the last reference to the context group is released.
    public func garbageCollect() { JSGarbageCollect(context) }

    /// The global object.
    public var global: JXValue {
        JXValue(env: self, valueRef: JSContextGetGlobalObject(context))
    }

    /// Tests whether global has a given property.
    ///
    /// - Parameters:
    ///   - property: The property's name.
    ///
    /// - Returns: true if the object has `property`, otherwise false.
    @inlinable public func hasProperty(_ property: String) -> Bool {
        global.hasProperty(property)
    }

    /// Deletes a property from global.
    ///
    /// - Parameters:
    ///   - property: The property's name.
    ///
    /// - Returns: true if the delete operation succeeds, otherwise false.
    @discardableResult
    @inlinable public func removeProperty(_ property: String) throws -> Bool {
        try global.removeProperty(property)
    }

    /// Returns the global property at the given subscript
    @inlinable public subscript(property: String) -> JXValue {
        get throws { try global[property] }
    }

    @inlinable public func setProperty(_ key: String, _ value: JXValue) throws {
        try global.setProperty(key, value)
    }

    /// Get the names of global’s enumerable properties
    @inlinable public var properties: [String] {
        global.properties
    }

    /// Checks for the presence of a top-level "exports" variable and creates it if it isn't already an object.
    @inlinable public func globalObject(property named: String) throws -> JXValue {
        let exp = try self.global[named]
        if exp.isObject {
            return exp
        } else {
            let exp = self.object()
            try self.global.setProperty(named, exp)
            return exp
        }
    }

    /// Invokes the given closure with the bytes without copying
    /// - Parameters:
    ///   - source: the data to use
    ///   - block: the block that passes the temporary JXValue wrapping the buffer data
    /// - Returns: the result of the closure
    public func withArrayBuffer<T>(source: Data, block: (JXValue) throws -> (T)) throws -> T {
        var source = source
        return try source.withUnsafeMutableBytes { bytes in
            let buffer = try JXValue(newArrayBufferWithBytesNoCopy: bytes,
                                 deallocator: { _ in
                //print("buffer deallocated")
            },
                                 in: self)
            return try block(buffer)
        }
    }

    /// Returns the global "Object"
    public var objectPrototype: JXValue {
        get throws {
            try global["Object"]
        }
    }

    /// Returns the global "Date"
    public var datePrototype: JXValue {
        get throws {
            try global["Date"]
        }
    }

    /// Returns the global "Array"
    public var arrayPrototype: JXValue {
        get throws {
            try global["Array"]
        }
    }

    /// Returns the global "ArrayBuffer"
    public var arrayBufferPrototype: JXValue {
        get throws {
            try global["ArrayBuffer"]
        }
    }

    /// Returns the global "Error"
    public var errorPrototype: JXValue {
        get throws {
            try global["Error"]
        }
    }

    @inlinable public func null() -> JXValue {
        JXValue(nullIn: self)
    }

    @inlinable public func undefined() -> JXValue {
        JXValue(undefinedIn: self)
    }

    @inlinable public func boolean(_ value: Bool) -> JXValue {
        JXValue(bool: value, in: self)
    }

    @inlinable public func number<F: BinaryFloatingPoint>(_ value: F) -> JXValue {
        JXValue(double: Double(value), in: self)
    }

    @inlinable public func number<I: BinaryInteger>(_ value: I) -> JXValue {
        JXValue(double: Double(value), in: self)
    }

    @inlinable public func string<S: StringProtocol>(_ value: S) -> JXValue {
        JXValue(string: String(value), in: self)
    }

    @inlinable public func object() -> JXValue {
        JXValue(newObjectIn: self)
    }

    /// Creates a new array in the environment
    @inlinable public func array(_ values: [JXValue]) throws -> JXValue {
        let array = try JXValue(newArrayIn: self)
        for (index, value) in values.enumerated() {
            try array.setElement(value, at: UInt32(index))
        }
        return array
    }


    @inlinable public func date(_ value: Date) throws -> JXValue {
        try JXValue(date: value, in: self)
    }

    @inlinable public func data<D: DataProtocol>(_ value: D) throws -> JXValue {
        try JXValue(newArrayBufferWithBytes: value, in: self)
    }
}