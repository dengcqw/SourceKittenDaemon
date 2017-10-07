import Foundation

internal enum CompletionResult {
    case success(result: [Array<String>])
    case failure(message: String)
    
    func asJSON() -> Data? {
        guard case .success(let result) = self,
            let json = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
            else { return nil }
        return json
    }
    
    func asJSONString() -> String {
        guard let data = self.asJSON() else { return "" }
        return String(data: data, encoding: String.Encoding.utf8) ?? ""
    }
}
