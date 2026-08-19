//
//  PPGDataSource.swift
//  PPGMonitor
//
import Foundation

protocol PPGDataSource: AnyObject {
    var onLine: ((String) -> Void)? {get set}
    var onStatusChange: ((Bool, String) -> Void)? {get set}
    
    func start()
    func stop()
}
