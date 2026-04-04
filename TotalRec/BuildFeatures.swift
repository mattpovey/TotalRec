import Foundation

enum BuildFeatures {
    #if ENABLE_NAME_SUGGESTIONS
    static let nameSuggestionsEnabled = true
    #else
    static let nameSuggestionsEnabled = false
    #endif
}
