// Compiles a Core ML .mlpackage into the .mlmodelc folder the app loads.
// Usage: swiftc -O compile_model.swift -o compile_model && ./compile_model in.mlpackage out.mlmodelc
import Foundation
import CoreML
let a = CommandLine.arguments
let tmp = try MLModel.compileModel(at: URL(fileURLWithPath: a[1]))
let dst = URL(fileURLWithPath: a[2])
try? FileManager.default.removeItem(at: dst)
try FileManager.default.moveItem(at: tmp, to: dst)
print("compiled", dst.path)
