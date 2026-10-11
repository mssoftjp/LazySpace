import ApplicationServices
import Darwin
import Foundation
import ObjectiveC

/// Private symbols, confined here. When missing they count as unavailable (never a crash).
public enum PrivateSymbols {
    typealias SLSMainConnectionIDFn = @convention(c) () -> Int32
    typealias SLSGetActiveSpaceFn = @convention(c) (Int32) -> UInt64
    typealias SLSCopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SLSCopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias SLSSpaceGetTypeFn = @convention(c) (Int32, UInt64) -> Int32
    typealias SLSWindowIsOrderedInFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<UInt8>) -> Int32
    typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    struct SkyLight {
        let mainConnectionID: SLSMainConnectionIDFn
        let getActiveSpace: SLSGetActiveSpaceFn
        let copyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFn
        let copySpacesForWindows: SLSCopySpacesForWindowsFn
        let spaceGetType: SLSSpaceGetTypeFn?
        let windowIsOrderedIn: SLSWindowIsOrderedInFn?
    }

    static let skyLight: SkyLight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: type)
        }
        guard let cid = load("SLSMainConnectionID", as: SLSMainConnectionIDFn.self),
              let active = load("SLSGetActiveSpace", as: SLSGetActiveSpaceFn.self),
              let managed = load("SLSCopyManagedDisplaySpaces", as: SLSCopyManagedDisplaySpacesFn.self),
              let forWindows = load("SLSCopySpacesForWindows", as: SLSCopySpacesForWindowsFn.self)
        else { return nil }
        return SkyLight(
            mainConnectionID: cid,
            getActiveSpace: active,
            copyManagedDisplaySpaces: managed,
            copySpacesForWindows: forWindows,
            spaceGetType: load("SLSSpaceGetType", as: SLSSpaceGetTypeFn.self),
            windowIsOrderedIn: load("SLSWindowIsOrderedIn", as: SLSWindowIsOrderedInFn.self)
        )
    }()

    /// The bridged operation that moves a window to another Space (the path WhichSpace and yabai use since `SLSMoveWindowsToManagedSpace`
    /// stopped working in macOS 14.5).
    /// Usable only when the class and both selectors exist; otherwise nil, and callers fall back to stepping.
    /// Asynchronous with no return value; success is confirmed through `SLSCopySpacesForWindows` membership.
    public struct BridgedSpaceMove {
        fileprivate let operationClass: AnyClass
        fileprivate let initialize: InitFn
        fileprivate let perform: PerformFn
        fileprivate static let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
        fileprivate static let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")
        /// Type encodings without stack offsets: `-(id)initWithWindows:(NSArray *)spaceID:(uint64_t)` and `-(void)perform...`.
        fileprivate static let initTypes = "@@:@Q"
        fileprivate static let performTypes = "v@:"
        fileprivate typealias InitFn = @convention(c) (AnyObject, Selector, CFArray, UInt64) -> Unmanaged<AnyObject>?
        fileprivate typealias PerformFn = @convention(c) (AnyObject, Selector) -> Void

        /// Sends the operation. Returns only whether it was sent (object created and perform called); membership is read separately.
        /// Ownership: `init` consumes the +1 from `alloc`, and its returned +1 goes to ARC (`takeRetainedValue`).
        public func move(_ ids: [CGWindowID], to spaceID: UInt64) -> Bool {
            guard !ids.isEmpty else { return false }
            guard let allocated = (operationClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return false }
            let windows = ids.map { NSNumber(value: $0) } as CFArray
            guard let operation = initialize(allocated, Self.initSelector, windows, spaceID)?.takeRetainedValue() else { return false }
            perform(operation, Self.performSelector)
            return true
        }

        /// A selector existing does not prove the ABI, so the IMP is used only when the type characters of its encoding match.
        fileprivate static func implementation(_ cls: AnyClass, _ selector: Selector, types: String) -> IMP? {
            guard let method = class_getInstanceMethod(cls, selector), let encoding = method_getTypeEncoding(method) else { return nil }
            let letters = String(cString: encoding).filter { !$0.isNumber }
            guard letters == types else { return nil }
            return method_getImplementation(method)
        }
    }

    public static let bridgedSpaceMove: BridgedSpaceMove? = {
        guard skyLight != nil,
              let cls: AnyClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              let initIMP = BridgedSpaceMove.implementation(cls, BridgedSpaceMove.initSelector, types: BridgedSpaceMove.initTypes),
              let performIMP = BridgedSpaceMove.implementation(cls, BridgedSpaceMove.performSelector, types: BridgedSpaceMove.performTypes) else { return nil }
        return BridgedSpaceMove(operationClass: cls,
                                initialize: unsafeBitCast(initIMP, to: BridgedSpaceMove.InitFn.self),
                                perform: unsafeBitCast(performIMP, to: BridgedSpaceMove.PerformFn.self))
    }()

    static let axUIElementGetWindow: AXUIElementGetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: AXUIElementGetWindowFn.self)
    }()

    private typealias SetDisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static let setDisclaim: SetDisclaimFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(sym, to: SetDisclaimFn.self)
    }()

    /// Makes a process spawned with these attributes responsible for itself, as Terminal does for its shells, so macOS
    /// privacy checks (TCC) never count the spawner's grants for it. False when the symbol is missing or refuses.
    public static func disclaimResponsibility(_ attributes: inout posix_spawnattr_t?) -> Bool {
        guard let setDisclaim else { return false }
        return setDisclaim(&attributes, 1) == 0
    }

    static var missing: [String] {
        var out: [String] = []
        if skyLight == nil { out.append("SkyLight SLS*") }
        if skyLight?.spaceGetType == nil { out.append("SLSSpaceGetType") }
        if axUIElementGetWindow == nil { out.append("_AXUIElementGetWindow") }
        return out
    }

    /// Symbolic hotkeys such as Mission Control's. Read on every call, never cached. There is no writer.
    enum SymbolicHotKey: Equatable {
        case unknown
        case disabled
        case enabled(keyCode: UInt32, flags: UInt32)
    }

    /// `CGSGetSymbolicHotKeyValue` / `CGSIsSymbolicHotKeyEnabled`, with the same types as the probe.
    /// The buffer is a zeroed `UInt32`: if the getter writes only 16 bits the upper half stays 0; 32 bits fill it.
    /// `unknown` when the symbol is missing or the getter returns nonzero. `disabled` only when the enabled bit is false.
    static func symbolicHotKey(_ id: Int32) -> SymbolicHotKey {
        guard let get = symbolicHotKeyValue, let enabled = symbolicHotKeyEnabled else { return .unknown }
        var equivalent = UInt32(0)
        var code = UInt32(0)
        var modifiers = UInt32(0)
        guard get(id, &equivalent, &code, &modifiers) == 0 else { return .unknown }
        guard enabled(id) else { return .disabled }
        return .enabled(keyCode: code, flags: modifiers)
    }

    private typealias CGSGetSymbolicHotKeyValueFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias CGSIsSymbolicHotKeyEnabledFn = @convention(c) (Int32) -> Bool

    private static let symbolicHotKeyValue: CGSGetSymbolicHotKeyValueFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSGetSymbolicHotKeyValue") else { return nil }
        return unsafeBitCast(symbol, to: CGSGetSymbolicHotKeyValueFn.self)
    }()

    private static let symbolicHotKeyEnabled: CGSIsSymbolicHotKeyEnabledFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSIsSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(symbol, to: CGSIsSymbolicHotKeyEnabledFn.self)
    }()
}
