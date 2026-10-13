//
//  JWTGenerator.swift
//  ar_flutter_plugin_plus
//
//  Created by Franz Graaf on 02.11.25.
//

import Foundation
import SwiftJWT

class JWTGenerator {
    
    func generateWebToken() -> String? {
        if let path = Bundle.main.path(forResource: "cloudAnchorKey", ofType: "json") {
            do {
              let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
              let jsonResult = try JSONSerialization.jsonObject(with: data, options: .mutableLeaves)
              if let jsonResult = jsonResult as? Dictionary<String, AnyObject>,
                 let privateKeyId = jsonResult["private_key_id"] as? String,
                 let privateKey = jsonResult["private_key"] as? String,
                 let clientEmail = jsonResult["client_email"] as? String {
                
                    let jwtTokenHeader = Header(typ: "JWT", kid: privateKeyId)
                    
                    struct JWTTokenClaims: Claims {
                        let iss: String
                        let sub: String
                        let iat: Date
                        let exp: Date
                        let aud: String
                    }
                    let jwtTokenClaims = JWTTokenClaims(iss: clientEmail, sub: clientEmail, iat: Date(), exp: Date(timeIntervalSinceNow: 3600), aud: "https://arcore.googleapis.com/")
                  
                    var jwtToken = JWT(header: jwtTokenHeader, claims: jwtTokenClaims)
                    
                    // Sign Token
                    let jwtSigner = JWTSigner.rs256(privateKey: privateKey.data(using: String.Encoding.ascii)!)
                    
                    let signedJwtToken = try jwtToken.sign(using: jwtSigner)
                    
                    return signedJwtToken
                  
                  }
              } catch {
                   print("Error generating JWT")
              }
        }
        return nil
    }
    
}
