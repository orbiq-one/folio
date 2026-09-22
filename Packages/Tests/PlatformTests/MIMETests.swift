import Foundation
import Testing
@testable import Platform

@Test func mimeUnfoldsHeadersAndDecodesQuotedPrintable() {
    let source = "Subject: Hello\r\n world\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\ncaf=E9=\r\n time=3Dnow"
    let parsed = MIMEParser.parse(Data(source.utf8))
    #expect(parsed.headers["subject"] == "Hello world")
    #expect(parsed.plainText == "café time=now")
}

@Test func mimeDecodesBase64AndWindowsCharset() {
    let source = "Content-Type: text/plain; charset=windows-1252\r\nContent-Transfer-Encoding: base64\r\n\r\n\(Data([0x93, 0x48, 0x69, 0x94]).base64EncodedString())"
    #expect(MIMEParser.parse(Data(source.utf8)).plainText == "“Hi”")
    #expect(MIMEParser.decodeHeader("=?UTF-8?B?SGVsbG8=?=") == "Hello")
    #expect(MIMEParser.decodeHeader("=?UTF-8?Q?caf=C3=A9?=\r\n =?UTF-8?Q?_today?=") == "café today")
    #expect(MIMEParser.decodeHeader("=?iso-8859-1?Q?caf=E9_au_lait?=") == "café au lait")
}

@Test func mimeNestedMultipartPreservesAlternativesAndAttachmentHash() throws {
    let source = """
    Subject: Test
    Content-Type: multipart/mixed; boundary="outer"

    Preamble is not body text.
    --outer
    Content-Type: multipart/alternative; boundary=inner

    --inner
    Content-Type: text/plain; charset=utf-8

    Hello
    --inner
    Content-Type: text/html
    Content-Transfer-Encoding: base64

    PGI+SGVsbG88L2I+
    --inner--
    --outer
    Content-Type: application/octet-stream; name="file.bin"
    Content-Disposition: attachment; filename="file.bin"
    Content-Transfer-Encoding: base64

    AAECAw==
    --outer--
    Epilogue is not body text.
    """
    let parsed = MIMEParser.parse(Data(source.utf8))
    #expect(parsed.plainText == "Hello")
    #expect(parsed.html == "<b>Hello</b>")
    let attachment = try #require(parsed.attachments.first)
    #expect(attachment.filename == "file.bin")
    #expect(attachment.size == 4)
    #expect(attachment.contentHash == "054edec1d0211f624fed0cbca9d4f9400b0e491c43742af2c5b0abebf0c990d8")
}

@Test func mimeBoundaryMustOccupyItsOwnLineAndBinaryBytesRemainIntact() throws {
    let source = "Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\nnot--x\r\n--x-not-boundary\r\n--x\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment\r\n\r\n"
    var data = Data(source.utf8)
    data.append(contentsOf: [0, 0xFF, 0xFE])
    data.append(Data("\r\n--x--\r\n".utf8))
    let parsed = MIMEParser.parse(data)
    #expect(parsed.plainText == "not--x\r\n--x-not-boundary")
    #expect(try #require(parsed.attachments.first).size == 3)
}

@Test func mimeMalformedEncodingDoesNotTrap() {
    #expect(MIMEParser.parse(Data()).plainText == "")
    #expect(MIMEParser.decode(Data("a=QZ=".utf8), transfer: "quoted-printable") == Data("a=QZ=".utf8))
    #expect(MIMEParser.parameter("boundary", in: "multipart/mixed; boundary=\"a;b\"") == "a;b")
    #expect(MIMEParser.parse(Data("Content-Type: multipart/mixed; boundary=x\n\n--x".utf8)).attachments.isEmpty)
}
