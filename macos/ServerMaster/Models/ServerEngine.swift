//
//  ServerEngine.swift
//  ServerMaster
//

import Foundation

/// What we host on.
nonisolated enum ServerEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case httpServer     // npm http-server
    case nodeScript     // node <entry>
    case pythonHTTP     // python3 -m http.server
    case phpBuiltIn     // php -S
    case nginx
    case phpFpm     // nginx + php-fpm
    case caddy
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .httpServer:  return "http-server (Node.js)"
        case .nodeScript:  return String(localized: "Node.js script")
        case .pythonHTTP:  return "Python http.server"
        case .phpBuiltIn:  return "PHP built-in server"
        case .nginx:       return "Nginx"
        case .phpFpm:      return String(localized: "PHP site (Nginx + PHP-FPM)")
        case .caddy:       return "Caddy"
        case .custom:      return String(localized: "Custom command")
        }
    }

    var subtitle: String {
        switch self {
        case .httpServer:  return String(localized: "Static files, HTTPS, CORS, caching, basic auth")
        case .nodeScript:  return String(localized: "Run your own server.js or npm script")
        case .pythonHTTP:  return String(localized: "Quick static serving, no HTTPS")
        case .phpBuiltIn:  return String(localized: "PHP routing, no HTTPS")
        case .nginx:       return String(localized: "Full config, HTTPS, proxying")
        case .phpFpm:      return String(localized: "For Joomla, WordPress and any PHP CMS")
        case .caddy:       return String(localized: "Auto config, HTTPS out of the box")
        case .custom:      return String(localized: "Any command with arguments")
        }
    }

    var symbol: String {
        switch self {
        case .httpServer, .nodeScript: return "shippingbox"
        case .pythonHTTP:              return "chevron.left.forwardslash.chevron.right"
        case .phpBuiltIn:              return "curlybraces"
        case .nginx:                   return "server.rack"
        case .phpFpm:                  return "cylinder.split.1x2"
        case .caddy:                   return "lock.shield"
        case .custom:                  return "terminal"
        }
    }

    /// Identifiers of the dependencies without which the engine will not start.
    var requiredTools: [String] {
        switch self {
        case .httpServer:  return ["node", "http-server"]
        case .nodeScript:  return ["node"]
        case .pythonHTTP:  return ["python3"]
        case .phpBuiltIn:  return ["php"]
        case .nginx:       return ["nginx"]
        case .phpFpm:      return ["nginx", "php-fpm"]
        case .caddy:       return ["caddy"]
        case .custom:      return []
        }
    }

    /// The engine can serve HTTPS on its own.
    var supportsHTTPS: Bool {
        switch self {
        case .httpServer, .nginx, .phpFpm, .caddy, .nodeScript, .custom: return true
        case .pythonHTTP, .phpBuiltIn: return false
        }
    }

    /// The engine needs a configuration file.
    var usesConfigFile: Bool {
        switch self {
        case .nginx, .caddy: return true
        default: return false
        }
    }

    /// The engine can serve custom error pages.
    var supportsErrorPages: Bool {
        switch self {
        case .nginx, .phpFpm, .caddy: return true
        default:                      return false
        }
    }

    /// The engine can set arbitrary response headers.
    var supportsCustomHeaders: Bool {
        switch self {
        case .nginx, .phpFpm, .caddy: return true
        default:                      return false
        }
    }

    /// The engine really does deny access to files starting with a dot.
    /// In http-server the --no-dotfiles flag only removes them from the directory
    /// listing; a direct request for .env still returns the contents.
    var blocksDotfileAccess: Bool {
        switch self {
        case .nginx, .phpFpm, .caddy: return true
        default:                      return false
        }
    }

    /// The engine at least hides such files from the directory listing.
    var hidesDotfilesFromListing: Bool {
        switch self {
        case .nginx, .phpFpm, .caddy, .httpServer: return true
        default:                          return false
        }
    }

    /// The engine needs a database alongside it (the typical CMS scenario).
    var typicallyNeedsDatabase: Bool { self == .phpFpm }

    /// The engine executes PHP.
    var runsPHP: Bool {
        switch self {
        case .phpFpm, .phpBuiltIn: return true
        default:                   return false
        }
    }

    var usesRootDirectory: Bool {
        switch self {
        case .custom: return false
        default: return true
        }
    }

    /// The default name of the generated config.
    var defaultConfigName: String? {
        switch self {
        case .nginx, .phpFpm: return "nginx.conf"
        case .caddy: return "Caddyfile"
        default:     return nil
        }
    }
}
