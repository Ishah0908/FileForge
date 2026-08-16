//
//  PPTXWriter.swift
//  FileForge
//
//  Writes a minimal, valid .pptx (OOXML) with one full-bleed image per slide.
//
//  Why hand-write OOXML instead of going through LibreOffice: Impress cannot
//  import a PDF at all, and the ODP → PPTX round trip drops the page images.
//  A picture-per-slide deck is a small, fully specified subset of the format,
//  so writing it directly is both more reliable and faster than shelling out.
//
//  A .pptx is a ZIP of XML parts. The minimum PowerPoint (and Keynote, and
//  Google Slides) will open is: content types, package rels, a presentation
//  part listing slide IDs, a slide master + layout, and one slide part per
//  slide with its own rels pointing at the image.
//
//  Author: Ibrahim Sultan
//

import Foundation

enum PPTXWriter {

    /// EMU (English Metric Units) per inch — OOXML's internal unit.
    /// 16:9 at 13.333in × 7.5in is PowerPoint's modern default slide.
    private static let slideWidth = 12192000
    private static let slideHeight = 6858000

    /// Build a .pptx at `output`, one slide per image, each filling the slide.
    static func write(imageURLs: [URL], to output: URL) throws {
        guard !imageURLs.isEmpty else {
            throw ForgeError.nothingFound("no slides to write")
        }

        let staging = try OutputNamer.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        let fm = FileManager.default
        for path in ["_rels", "docProps", "ppt/_rels", "ppt/slides/_rels",
                     "ppt/slideLayouts/_rels", "ppt/slideMasters/_rels", "ppt/media"] {
            try fm.createDirectory(at: staging.appendingPathComponent(path),
                                   withIntermediateDirectories: true)
        }

        let count = imageURLs.count
        let slideIndices = 1...count

        // Copy each rendered page in as media.
        for (i, url) in imageURLs.enumerated() {
            let dest = staging.appendingPathComponent("ppt/media/image\(i + 1).jpg")
            try fm.copyItem(at: url, to: dest)
        }

        // [Content_Types].xml — every part must be declared or the file won't open.
        var contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Default Extension="jpg" ContentType="image/jpeg"/>
            <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
            <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
            <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
            """
        for i in slideIndices {
            contentTypes += "\n<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        contentTypes += "\n</Types>"
        try write(contentTypes, to: staging.appendingPathComponent("[Content_Types].xml"))

        // Package relationships.
        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
            </Relationships>
            """, to: staging.appendingPathComponent("_rels/.rels"))

        // presentation.xml — slide IDs must start at 256 per the spec.
        var slideIdList = ""
        for i in slideIndices {
            slideIdList += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(i + 1)\"/>"
        }
        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
            <p:sldIdLst>\(slideIdList)</p:sldIdLst>
            <p:sldSz cx="\(slideWidth)" cy="\(slideHeight)"/>
            <p:notesSz cx="\(slideHeight)" cy="\(slideWidth)"/>
            </p:presentation>
            """, to: staging.appendingPathComponent("ppt/presentation.xml"))

        // presentation rels: the master, then one per slide.
        var presRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
            """
        for i in slideIndices {
            presRels += "\n<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i).xml\"/>"
        }
        presRels += "\n</Relationships>"
        try write(presRels, to: staging.appendingPathComponent("ppt/_rels/presentation.xml.rels"))

        try write(slideMasterXML, to: staging.appendingPathComponent("ppt/slideMasters/slideMaster1.xml"))
        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            </Relationships>
            """, to: staging.appendingPathComponent("ppt/slideMasters/_rels/slideMaster1.xml.rels"))

        try write(slideLayoutXML, to: staging.appendingPathComponent("ppt/slideLayouts/slideLayout1.xml"))
        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
            </Relationships>
            """, to: staging.appendingPathComponent("ppt/slideLayouts/_rels/slideLayout1.xml.rels"))

        // One slide part per page, each holding a single full-bleed picture.
        for i in slideIndices {
            try write(slideXML(index: i),
                      to: staging.appendingPathComponent("ppt/slides/slide\(i).xml"))
            try write("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
                <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\(i).jpg"/>
                </Relationships>
                """, to: staging.appendingPathComponent("ppt/slides/_rels/slide\(i).xml.rels"))
        }

        try zip(directory: staging, to: output)
    }

    // MARK: - Parts

    private static func slideXML(index: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
        <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        <p:pic>
        <p:nvPicPr><p:cNvPr id="\(index + 1)" name="Page \(index)"/>\
        <p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
        <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
        <p:spPr><a:xfrm><a:off x="0" y="0"/>\
        <a:ext cx="\(slideWidth)" cy="\(slideHeight)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
        </p:pic>
        </p:spTree></p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }

    private static let slideMasterXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
        <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        </p:spTree></p:cSld>
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" \
        accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" \
        hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        </p:sldMaster>
        """

    private static let slideLayoutXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank">
        <p:cSld name="Blank"><p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
        <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        </p:spTree></p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """

    // MARK: - Helpers

    private static func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Zip the staged directory into a .pptx.
    ///
    /// Uses `/usr/bin/zip` with `-X` (no extra attributes) so the archive
    /// carries nothing but the OOXML parts. Runs with the staging directory as
    /// the working directory, since the paths inside the archive must be
    /// relative to the package root.
    private static func zip(directory: URL, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-r", "-X", output.path, "."]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output.path) else {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "zip failed"
            throw ForgeError.toolFailed("PPTX", message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
