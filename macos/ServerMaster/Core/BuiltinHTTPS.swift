import Foundation
import Darwin

/// A Caddy TLS listener and an ordinary Python/PHP loopback backend supervised
/// as one launch. The same supervisor also runs under PrivilegedLauncher.
nonisolated enum BuiltinHTTPS {
    static func listener(host: String, port: Int) throws -> String {
        guard (1...65535).contains(port) else { throw LaunchPlanBuilder.BuildError.invalid(String(localized: "Invalid HTTPS port.")) }
        let host = host == "localhost" ? "127.0.0.1" : host
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return "\(host):\(port)" }
        if inet_pton(AF_INET6, host, &ipv6) == 1 { return "[\(host)]:\(port)" }
        throw LaunchPlanBuilder.BuildError.invalid(String(localized: "HTTPS listen host must be localhost or an IP address."))
    }

    static func configuration(profile: ServerProfile, backendPort: Int) throws -> String {
        guard backendPort != profile.port, (1024...65535).contains(backendPort) else {
            throw LaunchPlanBuilder.BuildError.invalid(String(localized: "Could not allocate a separate HTTPS backend port."))
        }
        let config: [String: Any] = [
            "admin": ["disabled": true, "config": ["persist": false]],
            "apps": [
                "tls": ["certificates": ["load_files": [["certificate": AppPaths.expand(profile.certificatePath), "key": AppPaths.expand(profile.privateKeyPath)]]]],
                "http": ["servers": ["site": [
                    "listen": [try listener(host: profile.host, port: profile.port)],
                    "automatic_https": ["disable": true],
                    "tls_connection_policies": [[:]],
                    "routes": [["handle": [["handler": "reverse_proxy", "upstreams": [["dial": "127.0.0.1:\(backendPort)"]]]]]]
                ]]]
            ]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    static func freeBackendPort(excluding publicPort: Int) throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LaunchPlanBuilder.BuildError.invalid(String(localized: "Could not allocate a separate HTTPS backend port.")) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        guard bound == 0, read == 0, port != publicPort, port >= 1024 else {
            throw LaunchPlanBuilder.BuildError.invalid(String(localized: "Could not allocate a separate HTTPS backend port."))
        }
        return port
    }

    /// Generated script uses private job-control groups, so PHP workers or
    /// other descendants are cleaned up without signalling unrelated servers.
    /// lsof checks the specific child PID, not merely whether a port is busy:
    /// losing the ephemeral-port race must never proxy to somebody else's site.
    static func supervisor(backend: LaunchPlan, caddy: String, configPath: String,
                           readyPath: String, backendPort: Int, publicPort: Int,
                           requireLoopbackBackend: Bool = false) throws -> String {
        let runtime = URL(fileURLWithPath: configPath).deletingLastPathComponent().path
        let primary = LaunchPlan(executable: caddy, arguments: ["run", "--config", configPath],
            workingDirectory: backend.workingDirectory,
            environment: ["XDG_DATA_HOME": runtime + "/caddy-data", "XDG_CONFIG_HOME": runtime + "/caddy-config"], generatedConfig: nil)
        return try supervisor(backend: backend, primary: primary, readyPath: readyPath,
                              backendPort: backendPort, publicPort: publicPort,
                              requireLoopbackBackend: requireLoopbackBackend)
    }

    /// Shared lifecycle for a listener and its private PHP/backend service.
    static func supervisor(backend: LaunchPlan, primary: LaunchPlan,
                           readyPath: String, backendPort: Int, publicPort: Int,
                           requireLoopbackBackend: Bool = false) throws -> String {
        let q = ProcessRunner.shellQuote
        func exports(_ environment: [String: String]) throws -> String {
            try environment.sorted { $0.key < $1.key }.map { key, value -> String in
                guard ServerProfile.isValidEnvironmentKey(key) else {
                    throw LaunchPlanBuilder.BuildError.invalid(String(localized: "Invalid environment variable name."))
                }
                return "export \(key)=\(q(value))"
            }.joined(separator: "\n")
        }
        let command = ([backend.executable] + backend.arguments).map(q).joined(separator: " ")
        let primaryCommand = ([primary.executable] + primary.arguments).map(q).joined(separator: " ")
        let backendCheck = requireLoopbackBackend ? """
            listeners=$(/usr/sbin/lsof -nP -a -p "$backend_pid" -iTCP:\(backendPort) -sTCP:LISTEN -Fn | /usr/bin/sed -n 's/^n//p' | /usr/bin/sort -u)
            if [ "$listeners" = '127.0.0.1:\(backendPort)' ]; then ready=1; break; fi
            if [ -n "$listeners" ]; then echo \(q(String(localized: "The Node.js backend must listen on its managed loopback address. Use the HOST and PORT environment variables."))) >&2; exit 1; fi
            """ : """
            if /usr/sbin/lsof -nP -a -p "$backend_pid" -iTCP:\(backendPort) -sTCP:LISTEN -t >/dev/null 2>&1; then ready=1; break; fi
            """
        return """
        #!/bin/bash
        set -m
        backend_pid=''
        proxy_pid=''
        child_alive() {
            kill -0 "$1" 2>/dev/null || return 1
            # kill -0 also succeeds for zombies. A privileged shell may not
            # reap asynchronous children until it explicitly waits for them.
            state=$(/bin/ps -p "$1" -o stat=)
            case "$state" in ''|*Z*) return 1 ;; esac
            return 0
        }
        cleanup() {
            trap '' TERM INT HUP
            for pid in "$proxy_pid" "$backend_pid"; do
                [ -z "$pid" ] || kill -TERM -- "-$pid" 2>/dev/null || true
            done
            for attempt in {1..25}; do
                alive=0
                for pid in "$proxy_pid" "$backend_pid"; do
                    if [ -n "$pid" ] && kill -0 -- "-$pid" 2>/dev/null; then alive=1; fi
                done
                [ "$alive" -eq 0 ] && break
                /bin/sleep 0.1
            done
            for pid in "$proxy_pid" "$backend_pid"; do
                [ -z "$pid" ] || kill -KILL -- "-$pid" 2>/dev/null || true
            done
            [ -z "$proxy_pid" ] || wait "$proxy_pid" 2>/dev/null || true
            [ -z "$backend_pid" ] || wait "$backend_pid" 2>/dev/null || true
            /bin/rm -f \(q(readyPath))
        }
        trap cleanup EXIT
        trap 'exit 0' TERM INT HUP
        /bin/rm -f \(q(readyPath))
        [ ! -e \(q(readyPath + ".stop")) ] || exit 0
        (
            \(try exports(backend.environment))
            cd \(q(backend.workingDirectory)) || exit 1
            unset PHP_CLI_SERVER_WORKERS
            exec \(command)
        ) &
        backend_pid=$!
        ready=0
        for attempt in {1..100}; do
            [ ! -e \(q(readyPath + ".stop")) ] || exit 0
            child_alive "$backend_pid" || { echo \(q(String(localized: "Backend exited before readiness."))) >&2; exit 1; }
            \(backendCheck)
            /bin/sleep 0.1
        done
        [ "$ready" -eq 1 ] || { echo \(q(String(localized: "Backend did not acquire its private port."))) >&2; exit 1; }
        (
            \(try exports(primary.environment))
            cd \(q(primary.workingDirectory)) || exit 1
            exec \(primaryCommand)
        ) &
        proxy_pid=$!
        ready=0
        for attempt in {1..100}; do
            [ ! -e \(q(readyPath + ".stop")) ] || exit 0
            child_alive "$backend_pid" && child_alive "$proxy_pid" || { echo \(q(String(localized: "Server process exited before readiness."))) >&2; exit 1; }
            if /usr/sbin/lsof -nP -a -p "$proxy_pid" -iTCP:\(publicPort) -sTCP:LISTEN -t >/dev/null 2>&1; then ready=1; break; fi
            /bin/sleep 0.1
        done
        [ "$ready" -eq 1 ] || { echo \(q(String(localized: "Server did not acquire its public port."))) >&2; exit 1; }
        echo ready > \(q(readyPath))
        while child_alive "$backend_pid" && child_alive "$proxy_pid"; do
            [ ! -e \(q(readyPath + ".stop")) ] || exit 0
            /bin/sleep 0.5
        done
        echo \(q(String(localized: "Server or backend exited; stopping the profile."))) >&2
        exit 1
        """
    }

    static func phpRouter(profile: ServerProfile) -> String {
        let canonical = PhpSiteCompatibility.isJoomla(root: AppPaths.expand(profile.rootPath))
            ? PhpSiteCompatibility.router.replacingOccurrences(of: "<?php", with: "") : "return false;"
        return """
        <?php
        // Only the isolated loopback backend consumes these proxy headers.
        if (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https') {
            $_SERVER['HTTPS'] = 'on';
            $_SERVER['REQUEST_SCHEME'] = 'https';
            $_SERVER['SERVER_PORT'] = '\(profile.port)';
        }
        \(canonical)
        """
    }

    static func wrap(profile: ServerProfile, backend original: LaunchPlan, caddy: String,
                     backendPort: Int, directory: String) throws -> LaunchPlan {
        var backend = original
        let config = directory + "/caddy.json"
        let ready = directory + "/ready"
        if profile.engine == .phpBuiltIn {
            let routerPath = backend.generatedConfig?.path ?? directory + "/php-router.php"
            if backend.generatedConfig == nil { backend.arguments.append(routerPath) }
            backend.generatedConfig = (routerPath, phpRouter(profile: profile))
        }
        var files = backend.extraFiles
        if let generated = backend.generatedConfig { files.append(generated) }
        files.append((config, try configuration(profile: profile, backendPort: backendPort)))
        let script = directory + "/supervisor.sh"
        return LaunchPlan(executable: "/bin/bash", arguments: [script],
                          workingDirectory: backend.workingDirectory, environment: backend.environment,
                          generatedConfig: (script, try supervisor(backend: backend, caddy: caddy,
                              configPath: config, readyPath: ready, backendPort: backendPort, publicPort: profile.port,
                              requireLoopbackBackend: profile.engine == .nodeScript)),
                          extraFiles: files, readinessFile: ready)
    }
}
