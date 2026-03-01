//
//  PhotoVerifyLogger.swift
//  StoreCheck
//
//  Created by Majdi Nagi on 3/1/26.
//


enum PhotoVerifyLogger {
    static func log(_ message: String) {
        #if DEBUG
        print("[PhotoVerify] \(message)")
        #endif
    }
}