import Foundation

func makeTemporaryDirectory() throws -> URL {
  let url = makeTemporaryURL()
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func makeTemporaryApplicationBundleDirectory() throws -> URL {
  let url = makeTemporaryURL(pathExtension: "app")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func makeTemporaryFile() throws -> URL {
  let url = makeTemporaryURL()
  try Data().write(to: url, options: .withoutOverwriting)
  return url
}

func makeTemporaryExecutable(_ body: String, in existingDirectory: URL? = nil) throws -> URL {
  let directory = try existingDirectory ?? makeTemporaryDirectory()
  let file = directory.appendingPathComponent("process-fixture")
  try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
  return file
}

private func makeTemporaryURL(pathExtension: String? = nil) -> URL {
  var url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  if let pathExtension {
    url.appendPathExtension(pathExtension)
  }
  return url
}
