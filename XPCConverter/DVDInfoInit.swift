import MovieArchiveConverter
import LibDVDRead


/* MARK: Toplevel */

extension DVDInfo {
	init?(_ ifoData: DVDData.IFO.All, _ navData: DVDData.NAV.All, discId: [UInt8]) {
		guard let vmgi = ifoData[.vmgi]?.pointee else { return nil }
		guard let vmgiMat = vmgi.vmgi_mat?.pointee else { return nil }
		guard let titleSets = Dictionary(titleSets: ifoData, navData) else { return nil }
		let firstPlayNav = navData[.vmgi]?[.firstPlay]?[.firstPlay]
		let vmgmNav = navData[.vmgi]?[.menus]
		self.init(specification: Version(vmgiMat.specification_version),
		          category: vmgiMat.vmg_category,
		          discId: discId,
		          provider: String(tuple: vmgiMat.provider_identifier),
		          posCode: vmgiMat.vmg_pos_code,
		          totalVolumeCount: vmgiMat.vmg_nr_of_volumes,
		          volumeIndex: vmgiMat.vmg_this_volume_nr,
		          discSide: vmgiMat.disc_side,
		          start: ProgramChain(vmgi.first_play_pgc?.pointee, navigation: firstPlayNav),
		          topLevelMenus: Domain(vmgi.pgci_ut?.pointee, vmgiMat, vmgmNav),
		          titleSets: titleSets)
	}
}

private extension DVDInfo.Version {
	init(_ combined: UInt8) {
		self.init(major: combined.bits(4...7), minor: combined.bits(0...3))
	}
}

private extension DVDInfo.Time {
	init(_ time: dvd_time_t) {
		// dvd_time_t is in binary coded decimals
		func bcd(_ value: UInt8) -> UInt8 {
			value.bits(0...3) + 10 * value.bits(4...7)
		}
		self.init(hours: bcd(time.hour),
		          minutes: bcd(time.minute),
		          seconds: bcd(time.second),
		          frames: bcd(time.frame_u.bits(0...5)),
		          rate: FrameRate(time.frame_u))
	}
	init(_ time: UInt64, rate: FrameRate) {
		let (hours, hoursRemainder) = time.quotientAndRemainder(dividingBy: 60 * 60 * 90_000)
		let (minutes, minutesRemainder) = hoursRemainder.quotientAndRemainder(dividingBy: 60 * 90_000)
		let (seconds, secondsRemainder) = minutesRemainder.quotientAndRemainder(dividingBy: 90_000)
		let frames: Double
		if case .framesPerSecond(let rate) = rate {
			frames = Double(secondsRemainder) / (90_000 / rate)
		} else {
			frames = 0
		}
		self.init(hours: UInt8(hours),
		          minutes: UInt8(minutes),
		          seconds: UInt8(seconds),
		          frames: UInt8(frames),
		          rate: rate)
	}
}

private extension DVDInfo.Time.FrameRate {
	init(_ frameInfo: UInt8) {
		switch frameInfo.bits(6...7) {
		case 1: self = .framesPerSecond(25.00)
		case 3: self = .framesPerSecond(29.97)
		default: self = .unexpected(frameInfo)
		}
	}
}


/* MARK: Title Set */

private extension Dictionary where Key == DVDInfo.Index<Value>, Value == DVDInfo.TitleSet {
	init?(titleSets ifoData: DVDData.IFO.All, _ navData: DVDData.NAV.All) {
		let titles: [DVDInfo.Index<DVDInfo.TitleSet.Title.AllTitles>: title_info_t]
		let titleTable = ifoData[.vmgi]?.pointee.tt_srpt?.pointee
		let titleStart = titleTable?.title
		let titleCount = titleTable?.nr_of_srpts
		let titleBuffer = UnsafeBufferPointer(start: titleStart, count: titleCount)
		titles = .init(uniqueKeysWithValues: zip(1..., titleBuffer))

		// these two sets of indexes should be identical
		let titleSetIndexes1 = titles.map(\.value.title_set_nr).map(Int.init)
		let titleSetIndexes2 = ifoData.keys.compactMap {
			if case .vtsi(let index) = $0 { return index } else { return nil }
		}
		let titleSetIndexes = Set().union(titleSetIndexes1).union(titleSetIndexes2)

		self.init(minimumCapacity: titleSetIndexes.count)
		for titleSetIndex in titleSetIndexes {
			guard let vtsi = ifoData[.vtsi(titleSetIndex)]?.pointee else { return nil }
			let titles = titles.filter { $0.value.title_set_nr == titleSetIndex }
			let nav = navData[.vtsi(titleSetIndex)]
			self[Key(titleSetIndex)] = Value(vtsi, vmgi: titles, navigation: nav)
		}
	}
}

private extension DVDInfo.TitleSet {
	init?(_ vtsi: ifo_handle_t, vmgi titles: [DVDInfo.Index<DVDInfo.TitleSet.Title.AllTitles>: title_info_t], navigation nav: DVDData.NAV.VTS?) {
		guard let vtsiMat = vtsi.vtsi_mat?.pointee else { return nil }
		self.init(specification: DVDInfo.Version(vtsiMat.specification_version),
		          category: vtsiMat.vts_category,
		          titles: Dictionary(vtsi.vts_ptt_srpt?.pointee, vmgi: titles),
		          menus: DVDInfo.Domain(vtsi.pgci_ut?.pointee, vtsiMat, nav?[.menus]),
		          content: DVDInfo.Domain(vtsi.vts_pgcit?.pointee, vtsiMat, nav?[.titles]))
	}
}

private extension Dictionary where Key == DVDInfo.Index<Value>, Value == DVDInfo.TitleSet.Title {
	init(_ pttSrpt: vts_ptt_srpt_t?, vmgi globalTitles: [DVDInfo.Index<DVDInfo.TitleSet.Title.AllTitles>: title_info_t]) {
		let titlesStart = pttSrpt?.title
		let titlesCount = pttSrpt?.nr_of_srpts
		let titlesBuffer = UnsafeBufferPointer(start: titlesStart, count: titlesCount)
		let parts: [[ptt_info_t]] = titlesBuffer.map {
			let partsStart = $0.ptt
			let partsCount = $0.nr_of_ptts
			let partsBuffer = UnsafeBufferPointer(start: partsStart, count: partsCount)
			return Array(partsBuffer)
		}

		let localIndexes = Set(globalTitles.map(\.value.vts_ttn)).map(Key.init)
		self.init(minimumCapacity: localIndexes.count)
		for localIndex in localIndexes {
			let titleInfo = globalTitles.first { $0.value.vts_ttn == localIndex.rawValue }!
			let partsIndex = Int(localIndex.rawValue) - 1  // one-based to zero-based
			let parts = partsIndex < parts.count ? parts[partsIndex] : []
			self[localIndex] = Value(titleInfo.value, parts: parts, globalIndex: titleInfo.key)
		}
	}
}

private extension DVDInfo.TitleSet.Title {
	init?(_ title: title_info_t, parts: [ptt_info_t], globalIndex: DVDInfo.Index<AllTitles>) {
		var jumpCommands = CommandPresence()
		if title.pb_ty.jlc_exists_in_tt_dom != 0 { jumpCommands.update(with: .features) }
		if title.pb_ty.jlc_exists_in_prepost_cmd != 0 { jumpCommands.update(with: .prePosts) }
		if title.pb_ty.jlc_exists_in_cell_cmd != 0 { jumpCommands.update(with: .cells) }
		if title.pb_ty.jlc_exists_in_button_cmd != 0 { jumpCommands.update(with: .buttons) }
		var restrictions = DVDInfo.Restrictions()
		if title.pb_ty.title_or_time_play != 0 { restrictions.update(with: .noJumpIntoTitle) }
		if title.pb_ty.chapter_search_or_play != 0 { restrictions.update(with: .noJumpToPart) }
		self.init(globalIndex: globalIndex,
		          parts: Dictionary(uniqueKeysWithValues: zip(1..., parts.map(Part.init))),
		          viewingAngleCount: title.nr_of_angles,
		          jumpCommands: jumpCommands,
		          linearPlayback: title.pb_ty.multi_or_random_pgc_title == 0,
		          restrictions: restrictions)
	}
}

private extension DVDInfo.TitleSet.Title.Part {
	init(_ part: ptt_info_t) {
		self.init(start: DVDInfo.Reference(programChain: .init(part.pgcn), program: .init(part.pgn)))
	}
}


/* MARK: Domain */

private extension DVDInfo.Domain {
	init?(_ pgcUt: pgci_ut_t?, _ vmgiMat: vmgi_mat_t, _ nav: DVDData.NAV.Domain?) {
		let pgcs = Self.convert(pgcsPerLanguage: pgcUt)
		guard pgcs.count > 0 else { return nil }
		self.init(programChains: ProgramChains(mapping: Dictionary(mapping: pgcs),
		                                       storage: Dictionary(storage: pgcs, navigation: nav)),
		          video: VideoAttributes(vmgiMat.vmgm_video_attr),
		          audio: vmgiMat.nr_of_vmgm_audio_streams == 0 ? [:] : [0: AudioAttributes(vmgiMat.vmgm_audio_attr)],
		          subpicture: vmgiMat.nr_of_vmgm_subp_streams == 0 ? [:] : [0: SubpictureAttributes(vmgiMat.vmgm_subp_attr)])
	}
	init?(_ pgcUt: pgci_ut_t?, _ vtsiMat: vtsi_mat_t, _ nav: DVDData.NAV.Domain?) {
		let pgcs = Self.convert(pgcsPerLanguage: pgcUt)
		guard pgcs.count > 0 else { return nil }
		self.init(programChains: ProgramChains(mapping: Dictionary(mapping: pgcs),
		                                       storage: Dictionary(storage: pgcs, navigation: nav)),
		          video: VideoAttributes(vtsiMat.vtsm_video_attr),
		          audio: vtsiMat.nr_of_vtsm_audio_streams == 0 ? [:] : [0: AudioAttributes(vtsiMat.vtsm_audio_attr)],
		          subpicture: vtsiMat.nr_of_vtsm_subp_streams == 0 ? [:] : [0: SubpictureAttributes(vtsiMat.vtsm_subp_attr)])
	}
	init?(_ pgcIt: pgcit_t?, _ vtsiMat: vtsi_mat_t, _ nav: DVDData.NAV.Domain?) {
		let audioChannel = Array<audio_attr_t>(tuple: vtsiMat.vts_audio_attr)
			.prefix(upTo: Int(vtsiMat.nr_of_vts_audio_streams))
		let multichannel = Array<multichannel_ext_t>(tuple: vtsiMat.vts_mu_audio_attr)
			.prefix(upTo: Int(vtsiMat.nr_of_vts_audio_streams))
		let audio = zip(audioChannel, multichannel).map { AudioAttributes($0.0, karaoke: $0.1) }
		let subpicture = Array<subp_attr_t>(tuple: vtsiMat.vts_subp_attr)
			.prefix(upTo: Int(vtsiMat.nr_of_vts_subp_streams))
			.map(SubpictureAttributes.init)

		let pgcs = Self.convert(pgcs: pgcIt)
		guard pgcs.count > 0 else { return nil }
		self.init(programChains: ProgramChains(mapping: Dictionary(mapping: pgcs),
		                                       storage: Dictionary(storage: pgcs, navigation: nav)),
		          video: VideoAttributes(vtsiMat.vts_video_attr),
		          audio: Dictionary(uniqueKeysWithValues: zip(0..., audio)),
		          subpicture: Dictionary(uniqueKeysWithValues: zip(0..., subpicture)))
	}
	static func convert(pgcsPerLanguage pgcUt: pgci_ut_t?) -> [pgci_lu_t: [pgci_srp_t]] {
		let languagesStart = pgcUt?.lu
		let languagesCount = pgcUt?.nr_of_lus
		let languagesBuffer = UnsafeBufferPointer(start: languagesStart, count: languagesCount)
		let languages = languagesBuffer.compactMap { $0.pgcit != nil ? $0 : nil }

		let laungagePgcs = languages.map { convert(pgcs: $0.pgcit?.pointee) }
		return Dictionary(uniqueKeysWithValues: zip(languages, laungagePgcs))
	}
	static func convert(pgcs pgcIt: pgcit_t?) -> [pgci_srp_t] {
		let pgcInfosStart = pgcIt?.pgci_srp
		let pgcInfosCount = pgcIt?.nr_of_pgci_srp
		let pgcInfosBuffer = UnsafeBufferPointer(start: pgcInfosStart, count: pgcInfosCount)
		return Array(pgcInfosBuffer)
	}
}

private extension Dictionary<DVDInfo.Domain.ProgramChains.Descriptor, DVDInfo.Domain.ProgramChains.Id> {
	init(mapping pgcs: [pgci_lu_t: [pgci_srp_t]]) {
		self.init(minimumCapacity: pgcs.map(\.value.count).reduce(0, +))
		for (language, pgcs) in pgcs {
			for (index, pgcInfo) in zip(1..., pgcs) {
				let menuType = Key.MenuType(pgcInfo.entry_id.bits(0...3))
				let descriptor = Key.menu(language: String(twoCharacters: language.lang_code),
				                          entryPoint: pgcInfo.entry_id.bit(7),
				                          type: pgcInfo.entry_id.bit(7) ? menuType : nil,
				                          index: DVDInfo.Index(index))
				self[descriptor] = Value(languageId: language.lang_start_byte,
				                         programChainId: pgcInfo.pgc_start_byte)
			}
		}
	}
	init(mapping pgcs: [pgci_srp_t]) {
		self.init(minimumCapacity: pgcs.count)
		for (index, pgcInfo) in zip(1..., pgcs) {
			let descriptor = Key.title(title: DVDInfo.Index(pgcInfo.entry_id.bits(0...6)),
			                           entryPoint: pgcInfo.entry_id.bit(7),
			                           index: DVDInfo.Index(index))
			self[descriptor] = Value(programChainId: pgcInfo.pgc_start_byte)
		}
	}
}

private extension Dictionary<DVDInfo.Domain.ProgramChains.Id, DVDInfo.ProgramChain> {
	init(storage pgcs: [pgci_lu_t: [pgci_srp_t]], navigation: DVDData.NAV.Domain?) {
		self.init(minimumCapacity: pgcs.map(\.value.count).reduce(0, +))
		for (language, pgcs) in pgcs {
			for pgcInfo in pgcs {
				guard let pgc = pgcInfo.pgc?.pointee else { continue }
				let id = Key(languageId: language.lang_start_byte,
				             programChainId: pgcInfo.pgc_start_byte)
				let nav = navigation?[.menu(language: language.lang_start_byte,
				                            pgc: pgcInfo.pgc_start_byte)]
				self[id] = Value(pgc, navigation: nav)
			}
		}
	}
	init(storage pgcs: [pgci_srp_t], navigation: DVDData.NAV.Domain?) {
		self.init(minimumCapacity: pgcs.count)
		for pgcInfo in pgcs {
			guard let pgc = pgcInfo.pgc?.pointee else { continue }
			let id = Key(programChainId: pgcInfo.pgc_start_byte)
			let nav = navigation?[.title(pgc: pgcInfo.pgc_start_byte)]
			self[id] = Value(pgc, navigation: nav)
		}
	}
}

private extension DVDInfo.Domain.ProgramChains.Descriptor.MenuType {
	init(_ entry: UInt8) {
		switch entry {
		case 2: self = .titles
		case 3: self = .rootWithinTitle
		case 4: self = .subpicture
		case 5: self = .audio
		case 6: self = .viewingAngle
		case 7: self = .chapter
		default: self = .unexpected(entry)
		}
	}
}

private extension DVDInfo.Domain.VideoAttributes {
	init(_ attrs: video_attr_t) {
		let standard = VideoStandard(attrs.video_format)
		var allowedDisplay = DisplayModification()
		if !attrs.permitted_df.bit(0) { allowedDisplay.update(with: .letterbox) }
		if !attrs.permitted_df.bit(1) { allowedDisplay.update(with: .panScan) }
		var line21cc = Line21ClosedCaption()
		if attrs.line21_cc_1 != 0 { line21cc.update(with: .firstField) }
		if attrs.line21_cc_2 != 0 { line21cc.update(with: .secondField) }
		self.init(coding: CodingType(attrs.mpeg_version),
		          standard: standard,
		          codedPicture: Resolution(attrs.picture_size, videoStandard: standard),
		          displayAspect: AspectRatio(attrs.display_aspect_ratio, letterboxed: attrs.letterboxed != 0),
		          allowedDisplay: allowedDisplay,
		          line21cc: line21cc,
		          content: ContentInfo(attrs.film_mode))
	}
}

private extension DVDInfo.Domain.VideoAttributes.CodingType {
	init(_ mpegVersion: UInt8) {
		switch mpegVersion {
		case 0: self = .mpeg1
		case 1: self = .mpeg2
		default: self = .unexpected(mpegVersion)
		}
	}
}

private extension DVDInfo.Domain.VideoAttributes.VideoStandard {
	init(_ videoFormat: UInt8) {
		switch videoFormat {
		case 0: self = .ntsc
		case 1: self = .pal
		default: self = .unexpected(videoFormat)
		}
	}
}

private extension DVDInfo.Domain.VideoAttributes.Resolution {
	init(_ pictureSize: UInt8, videoStandard standard: DVDInfo.Domain.VideoAttributes.VideoStandard) {
		var width, height: UInt16?
		switch standard {
		case .ntsc: height = 480
		case .pal: height = 576
		default: height = nil
		}
		switch pictureSize {
		case 0: width = 720
		case 1: width = 704
		case 2: width = 352
		case 3:
			width = 352
			height = height.map { $0 / 2 }
		default:
			width = nil
			height = nil
		}
		self.init(width: width, height: height)
	}
}

private extension DVDInfo.Domain.VideoAttributes.AspectRatio {
	init(_ displayAspectRatio: UInt8, letterboxed: Bool) {
		switch displayAspectRatio {
		case 0: self = .classic(letterboxed: letterboxed)
		case 1: self = .unspecified
		case 3: self = .wide
		default: self = .unexpected(displayAspectRatio)
		}
	}
}

private extension DVDInfo.Domain.VideoAttributes.ContentInfo {
	init(_ filmMode: UInt8) {
		switch filmMode {
		case 0: self = .video
		case 1: self = .film
		default: fatalError("illegal value \(filmMode)")
		}
	}
}

private extension DVDInfo.Domain.AudioAttributes {
	init(_ attrs: audio_attr_t, karaoke: multichannel_ext_t? = nil) {
		self.init(coding: CodingType(attrs.audio_format, additional: attrs.quantization),
		          sampleFrequency: UInt32(attrs.sample_frequency == 0 ? 48000 : 96000),
		          channelCount: attrs.channels + 1,
		          rendering: RenderingIntent(attrs.application_mode, additional: attrs.app_info, karaoke: attrs.multichannel_extension != 0 ? karaoke : nil),
		          language: attrs.lang_type != 0 ? String(twoCharacters: attrs.lang_code) : nil,
		          content: ContentInfo(attrs.code_extension))
	}
}

private extension DVDInfo.Domain.AudioAttributes.CodingType {
	init(_ audioFormat: UInt8, additional info: UInt8) {
		switch audioFormat {
		case 0: self = .ac3
		case 2: self = .mpeg1(dynamicRangeCompression: info != 0)
		case 3: self = .mpeg2(dynamicRangeCompression: info != 0)
		case 4:
			switch info {
			case 0: self = .lpcm(bitsPerSample: 16)
			case 1: self = .lpcm(bitsPerSample: 20)
			case 2: self = .lpcm(bitsPerSample: 24)
			default: self = .unexpected(audioFormat, info)
			}
		case 6: self = .dts
		default: self = .unexpected(audioFormat, info)
		}
	}
}

private extension DVDInfo.Domain.AudioAttributes.RenderingIntent {
	init(_ applicationMode: UInt8, additional info: audio_attr_t.__Unnamed_union_app_info, karaoke multiChannel: multichannel_ext_t?) {
		switch applicationMode {
		case 0: self = .normal
		case 1: self = .karaoke(version: info.karaoke.version,
		                        mode: Karaoke.Mode(info.karaoke.mode),
		                        channels: multiChannel != nil ? Array(multiChannel!) : Array(info.karaoke.channel_assignment),
		                        multiChannelIntro: info.karaoke.mc_intro == 0)
		case 2: self = .surround(dolbyMatrixEncoded: info.surround.dolby_encoded != 0)
		default: self = .unexpected(applicationMode)
		}
	}
}

private extension DVDInfo.Domain.AudioAttributes.RenderingIntent.Karaoke.Mode {
	init(_ mode: UInt8) {
		switch mode {
		case 0: self = .solo
		case 1: self = .duet
		default: fatalError("illegal value \(mode)")
		}
	}
}

private extension Array<DVDInfo.Domain.AudioAttributes.RenderingIntent.Karaoke.Channel> {
	init(_ multiChannel: multichannel_ext_t) {
		self = [.left, .right, .center, .surround, .surround]
		if multiChannel.ach0_gme != 0 { self[0] = .guideMelody() }
		if multiChannel.ach1_gme != 0 { self[1] = .guideMelody() }
		if multiChannel.ach2_gm1e != 0 { self[2] = .guideMelody("1") }
		if multiChannel.ach2_gm2e != 0 { self[2] = .guideMelody("2") }
		if multiChannel.ach2_gv1e != 0 { self[2] = .guideVocal("1") }
		if multiChannel.ach2_gv2e != 0 { self[2] = .guideVocal("2") }
		if multiChannel.ach3_gmAe != 0 { self[3] = .guideMelody("A") }
		if multiChannel.ach3_gv1e != 0 { self[3] = .guideVocal("1") }
		if multiChannel.ach3_gv2e != 0 { self[3] = .guideVocal("2") }
		if multiChannel.ach3_se2e != 0 { self[3] = .effect("A") }
		if multiChannel.ach4_gmBe != 0 { self[4] = .guideMelody("B") }
		if multiChannel.ach4_gv1e != 0 { self[4] = .guideVocal("1") }
		if multiChannel.ach4_gv2e != 0 { self[4] = .guideVocal("2") }
		if multiChannel.ach4_seBe != 0 { self[4] = .effect("B") }
	}
	init(_ channelAssignment: UInt8) {
		switch channelAssignment {
		case 2: self = [.left, .right]
		case 3: self = [.left, .guideMelody(), .right]
		case 4: self = [.left, .right, .guideVocal()]
		case 5: self = [.left, .guideMelody(), .right, .guideVocal()]
		case 6: self = [.left, .right, .guideVocal("1"), .guideVocal("2")]
		case 7: self = [.left, .guideMelody(), .right, .guideVocal("1"), .guideVocal("2")]
		default: self = []
		}
	}
}

private extension DVDInfo.Domain.AudioAttributes.ContentInfo {
	init(_ codeExtension: UInt8) {
		switch codeExtension {
		case 0: self = .unspecified
		case 1: self = .sourceAudio
		case 2: self = .audioDescription
		case 3: self = .commentary
		case 4: self = .alternateCommentary
		default: self = .unexpected(codeExtension)
		}
	}
}

private extension DVDInfo.Domain.SubpictureAttributes {
	init(_ attrs: subp_attr_t) {
		self.init(coding: CodingType(attrs.code_mode),
		          language: attrs.type != 0 ? String(twoCharacters: attrs.lang_code) : nil,
		          content: ContentInfo(attrs.code_extension))
	}
}

private extension DVDInfo.Domain.SubpictureAttributes.CodingType {
	init(_ codeMode: UInt8) {
		switch codeMode {
		case 0: self = .rle
		case 1: self = .extended
		default: self = .unexpected(codeMode)
		}
	}
}

private extension DVDInfo.Domain.SubpictureAttributes.ContentInfo {
	init(_ codeExtension: UInt8) {
		switch codeExtension {
		case 0: self = .unspecified
		case 1: self = .subtitles(fontSize: .normal, forChildren: false)
		case 2: self = .subtitles(fontSize: .large, forChildren: false)
		case 3: self = .subtitles(fontSize: .normal, forChildren: true)
		case 5: self = .closedCaptions(fontSize: .normal, forChildren: false)
		case 6: self = .closedCaptions(fontSize: .large, forChildren: false)
		case 7: self = .closedCaptions(fontSize: .normal, forChildren: true)
		case 9: self = .forced
		case 13: self = .commentary(fontSize: .normal, forChildren: false)
		case 14: self = .commentary(fontSize: .large, forChildren: false)
		case 15: self = .commentary(fontSize: .normal, forChildren: true)
		default: self = .unexpected(codeExtension)
		}
	}
}


/* MARK: Program Chain */

private extension DVDInfo.ProgramChain {
	init(_ pgc: pgc_t, navigation: DVDData.NAV.PGC?) {
		let programsStart = pgc.program_map
		let programsCount = pgc.nr_of_programs
		let programsBuffer = UnsafeBufferPointer(start: programsStart, count: programsCount)
		let programs = Array(programsBuffer)

		let cellsStart = pgc.cell_playback
		let cellsCount = pgc.nr_of_cells
		let cellsBuffer = UnsafeBufferPointer(start: cellsStart, count: cellsCount)
		let cells = Array(cellsBuffer)

		let pre: [vm_cmd_t]
		let post: [vm_cmd_t]
		let cellPost: [vm_cmd_t]
		if let cmd = pgc.command_tbl?.pointee {
			let preStart = cmd.pre_cmds
			let preCount = cmd.nr_of_pre
			let preBuffer = UnsafeBufferPointer(start: preStart, count: preCount)
			pre = Array(preBuffer)
			let postStart = cmd.post_cmds
			let postCount = cmd.nr_of_post
			let postBuffer = UnsafeBufferPointer(start: postStart, count: postCount)
			post = Array(postBuffer)
			let cellStart = cmd.cell_cmds
			let cellCount = cmd.nr_of_cell
			let cellBuffer = UnsafeBufferPointer(start: cellStart, count: cellCount)
			cellPost = Array(cellBuffer)
		} else {
			pre = []; post = []; cellPost = []
		}

		func cellInit(_ pair: (key: Int, value: cell_playback_t)) -> (DVDInfo.Index<Cell>, Cell) {
			(DVDInfo.Index(pair.key), Cell(pair.value, navigation: navigation?[pair.key - 1]))
		}

		self.init(programs: Dictionary(uniqueKeysWithValues: zip(1..., programs.map(Program.init))),
		          cells: Dictionary(uniqueKeysWithValues: zip(1..., cells).map(cellInit)),
		          duration: DVDInfo.Time(pgc.playback_time),
		          playback: PlaybackMode(pgc.pg_playback_mode),
		          ending: EndingMode(pgc.still_time),
		          mapAudio: Dictionary(audio: pgc.audio_control),
		          mapSubpicture: Dictionary(subpicture: pgc.subp_control),
		          next: pgc.next_pgc_nr != 0 ? DVDInfo.Reference(programChain: .init(pgc.next_pgc_nr)) : nil,
		          previous: pgc.prev_pgc_nr != 0 ? DVDInfo.Reference(programChain: .init(pgc.prev_pgc_nr)) : nil,
		          up: pgc.goup_pgc_nr != 0 ? DVDInfo.Reference(programChain: .init(pgc.goup_pgc_nr)) : nil,
		          pre: Dictionary(uniqueKeysWithValues: zip(1..., pre.map(DVDInfo.Command.init))),
		          post: Dictionary(uniqueKeysWithValues: zip(1..., post.map(DVDInfo.Command.init))),
		          cellPost: Dictionary(uniqueKeysWithValues: zip(1..., cellPost.map(DVDInfo.Command.init))),
		          buttonPalette: Dictionary(palette: pgc.palette, navigation: navigation ?? []),
		          restrictions: DVDInfo.Restrictions(pgc.prohibited_ops))
	}
	init?(_ pgc: pgc_t?, navigation: DVDData.NAV.PGC?) {
		guard let pgc else { return nil }
		self.init(pgc, navigation: navigation)
	}
}

private extension DVDInfo.ProgramChain.Program {
	init(_ program: pgc_program_map_t) {
		self.init(start: DVDInfo.Reference(cell: .init(program)))
	}
}

private extension DVDInfo.ProgramChain.Cell {
	init(_ cell: cell_playback_t, navigation: DVDData.NAV.Cell?) {
		var playback = PlaybackMode()
		if cell.seamless_play != 0 { playback.update(with: .seamless) }
		if cell.interleaved != 0 { playback.update(with: .interleaved) }
		if cell.stc_discontinuity != 0 { playback.update(with: .timeDiscontinuity) }
		if cell.seamless_angle != 0 { playback.update(with: .seamlessAngle) }
		if cell.playback_mode != 0 { playback.update(with: .allStillFrames) }
		if cell.restricted != 0 { playback.update(with: .stopFastForward) }
		self.init(duration: DVDInfo.Time(cell.playback_time),
		          playback: playback,
		          ending: EndingMode(cell.still_time),
		          angle: AngleInfo(block: cell.block_type, cell: cell.block_mode),
		          karaoke: KaraokeInfo(cell.cell_type),
		          interaction: navigation?.compactMap(DVDInfo.Interaction.init) ?? [],
		          post: cell.cell_cmd_nr != 0 ? DVDInfo.Reference(command: .init(cell.cell_cmd_nr)) : nil,
		          sectors: DVDInfo.Index<DVDInfo.Sector>(cell.first_sector)...DVDInfo.Index<DVDInfo.Sector>(cell.last_sector))
	}
}

private extension DVDInfo.ProgramChain.Cell.AngleInfo {
	init?(block: UInt32, cell: UInt32) {
		if block == 0 && cell == 0 {
			return nil
		} else if block == 1 {
			switch cell {
			case 0: self = .externalCell
			case 1: self = .firstCellInBlock
			case 2: self = .innerCellInBlock
			case 3: self = .lastCellInBlock
			default: fatalError("illegal value \(cell)")
			}
		} else {
			self = .unexpected(block)
		}
	}
}

private extension DVDInfo.ProgramChain.Cell.KaraokeInfo {
	init?(_ cellType: UInt32) {
		switch cellType {
		case 0: return nil
		case 1: self = .titlePicture
		case 2: self = .introduction
		case 3: self = .bridge
		case 4: self = .firstClimax
		case 5: self = .secondClimax
		case 6: self = .maleVocal
		case 7: self = .femaleVocal
		case 8: self = .mixedVocal
		case 9: self = .interlude
		case 10: self = .interludeFadeIn
		case 11: self = .interludeFadeOut
		case 12: self = .firstEnding
		case 13: self = .secondEnding
		default: self = .unexpected(cellType)
		}
	}
}

private extension DVDInfo.ProgramChain.PlaybackMode {
	init(_ playbackMode: UInt8) {
		if playbackMode == 0 {
			self = .sequential
		} else if playbackMode.bit(7) {
			self = .random(programCount: playbackMode.bits(0...6) + 1)
		} else {
			self = .shuffle(programCount: playbackMode.bits(0...6) + 1)
		}
	}
}

private extension DVDInfo.ProgramChain.EndingMode {
	init(_ still: UInt8) {
		switch still {
		case UInt8.min: self = .immediate
		case UInt8.max: self = .holdLastFrameIndefinitely
		default: self = .holdLastFrame(seconds: still)
		}
	}
}

private extension Dictionary where Key == DVDInfo.Index<DVDInfo.LogicalAudioStream>, Value == DVDInfo.Index<DVDInfo.VOBAudioStream> {
	init(audio: (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16)) {
		self.init()
		let elements = Array<UInt16>(tuple: audio)
		for (index, stream) in zip(0..., elements) where stream.bit(15) {
			self[Key(index)] = Value(stream.bits(8...10))
		}
	}
}

private extension Dictionary where Key == DVDInfo.Index<DVDInfo.LogicalSubpictureStream>, Value == [DVDInfo.ProgramChain.SubpictureDescriptor: DVDInfo.Index<DVDInfo.VOBSubpictureStream>] {
	init(subpicture: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
	                  UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
	                  UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
	                  UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)) {
		self.init()
		let elements = Array<UInt32>(tuple: subpicture)
		for (index, stream) in zip(0..., elements) where stream.bit(31) {
			self[Key(index)] = [
				.classic:   DVDInfo.Index(stream.bits(24...28)),
				.wide:      DVDInfo.Index(stream.bits(16...20)),
				.letterbox: DVDInfo.Index(stream.bits(8...12)),
				.panScan:   DVDInfo.Index(stream.bits(0...4))
			]
		}
	}
}

private extension Dictionary where Key == DVDInfo.Index<Value>, Value == DVDInfo.ProgramChain.Color {
	init(palette: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
	               UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
	     navigation: DVDData.NAV.PGC) {
		// palette entries cannot be marked as unused, so we detect usage ourselves
		let usedColors = navigation.reduce(into: Set<Int>()) { result, cellNav in
			let usedColors = cellNav.reduce(into: Set<Int>()) { result, nav in
				// only consider new highlight information with active buttons
				guard nav.pci.hli.hl_gi.hli_ss.bit(0) && nav.pci.hli.hl_gi.btn_ns > 0 else { return }
				let colors = [
					nav.pci.hli.btn_colit.btn_coli.0.0,
					nav.pci.hli.btn_colit.btn_coli.0.1,
					nav.pci.hli.btn_colit.btn_coli.1.0,
					nav.pci.hli.btn_colit.btn_coli.1.1,
					nav.pci.hli.btn_colit.btn_coli.2.0,
					nav.pci.hli.btn_colit.btn_coli.2.1
				]
				colors.forEach {
					result.insert(Int($0.bits(16...19)))
					result.insert(Int($0.bits(20...23)))
					result.insert(Int($0.bits(24...27)))
					result.insert(Int($0.bits(28...31)))
				}
			}
			result.formUnion(usedColors)
		}
		self.init()
		let elements = Array<UInt32>(tuple: palette)
		for (index, color) in zip(0..., elements) where usedColors.contains(index) {
			self[Key(index)] = Value(color)
		}
	}
}

private extension DVDInfo.ProgramChain.Color {
	init(_ color: UInt32) {
		self.init(Y: UInt8(color.bits(16...23)),
		          Cb: UInt8(color.bits(8...15)),
		          Cr: UInt8(color.bits(0...7)))
	}
}


/* MARK: Interaction */

private extension DVDInfo.Interaction {
	init?(_ nav: DVDData.NAV.NAVPacket) {
		// only consider new highlight information with active buttons
		guard nav.pci.hli.hl_gi.hli_ss.bit(0) && nav.pci.hli.hl_gi.btn_ns > 0 else { return nil }

		let startOffset = nav.pci.hli.hl_gi.hli_s_ptm - nav.pci.pci_gi.vobu_s_ptm
		let start = nav.timestamp.map { $0 + UInt64(startOffset) }
		let selectable = nav.pci.hli.hl_gi.btn_se_e_ptm < UInt32.max ? nav.pci.hli.hl_gi.btn_se_e_ptm - nav.pci.hli.hl_gi.hli_s_ptm : nil
		let visible = nav.pci.hli.hl_gi.hli_e_ptm < UInt32.max ? nav.pci.hli.hl_gi.hli_e_ptm - nav.pci.hli.hl_gi.hli_s_ptm : nil
		let frameRate = DVDInfo.Time.FrameRate(nav.pci.pci_gi.e_eltm.frame_u)

		self.init(sector: DVDInfo.Index(nav.pci.pci_gi.nv_pck_lbn),
		          linearPlaybackTimestamp: start.map { DVDInfo.Time($0, rate: frameRate) },
		          onlyCommandsChanged: nav.pci.hli.hl_gi.hli_ss.bits(0...1) == 3,
		          buttons: Dictionary(buttons: nav.pci.hli),
		          buttonsSelectable: selectable.map { DVDInfo.Time(UInt64($0), rate: frameRate) },
		          buttonsVisible: visible.map { DVDInfo.Time(UInt64($0), rate: frameRate) },
		          forcedSelect: nav.pci.hli.hl_gi.fosl_btnn > 0 ? DVDInfo.Index(nav.pci.hli.hl_gi.fosl_btnn) : nil,
		          forcedAction: nav.pci.hli.hl_gi.foac_btnn > 0 ? DVDInfo.Index(nav.pci.hli.hl_gi.foac_btnn) : nil,
		          restrictions: DVDInfo.Restrictions(nav.pci.pci_gi.vobu_uop_ctl))
	}
}

private extension Dictionary where Key == DVDInfo.Index<DVDInfo.Interaction.Button>, Value == [DVDInfo.Interaction.ButtonDescriptor: DVDInfo.Interaction.Button] {
	init(buttons hli: hli_t) {
		let buttonArray = Array<btni_t>(tuple: hli.btnit)
		let buttonNumbers = 1...Int(hli.hl_gi.btn_ns)
		let buttonGroups = 1...Int(hli.hl_gi.btngr_ns)

		let buttons = buttonNumbers.map { buttonNumber -> (Key, Value) in
			let buttonGroup = buttonGroups.compactMap { buttonGroup -> (Value.Key, Value.Value)? in

				let descriptor: DVDInfo.Interaction.ButtonDescriptor
				switch buttonGroup {
				case 1:	descriptor = .init(rawValue: hli.hl_gi.btngr1_dsp_ty)
				case 2: descriptor = .init(rawValue: hli.hl_gi.btngr2_dsp_ty)
				case 3: descriptor = .init(rawValue: hli.hl_gi.btngr3_dsp_ty)
				default: return nil
				}

				let groupStartIndex = (buttonGroup - 1) * 36 / buttonGroups.count
				let buttonIndex = groupStartIndex + (buttonNumber - 1)
				guard buttonIndex < buttonArray.endIndex else { return nil }
				let button = DVDInfo.Interaction.Button(buttonArray[buttonIndex], color: hli.btn_colit)

				return (descriptor, button)
			}
			return (Key(buttonNumber), Value(uniqueKeysWithValues: buttonGroup))
		}
		self.init(uniqueKeysWithValues: buttons)
	}
}

private extension DVDInfo.Interaction.Button {
	init(_ btnit: btni_t, color btn_colit: btn_colit_t) {
		let colorInfo: (UInt32, UInt32)?
		switch btnit.btn_coln {
		case 1: colorInfo = btn_colit.btn_coli.0
		case 2: colorInfo = btn_colit.btn_coli.1
		case 3: colorInfo = btn_colit.btn_coli.2
		default: colorInfo = nil
		}

		self.init(mask: Rectangle(xStart: btnit.x_start, xEnd: btnit.x_end,
		                          yStart: btnit.y_start, yEnd: btnit.y_end),
		          up: btnit.up != 0 ? DVDInfo.Reference(button: .init(btnit.up)) : nil,
		          down: btnit.down != 0 ? DVDInfo.Reference(button: .init(btnit.down)) : nil,
		          left: btnit.left != 0 ? DVDInfo.Reference(button: .init(btnit.left)) : nil,
		          right: btnit.right != 0 ? DVDInfo.Reference(button: .init(btnit.right)) : nil,
		          selectionColors: colorInfo.map { Array(colors: $0.0) },
		          actionColors: colorInfo.map { Array(colors: $0.1) },
		          action: DVDInfo.Command(btnit.cmd),
		          autoActionOnSelect: btnit.auto_action_mode != 0)
	}
}

private extension Array<DVDInfo.Interaction.Button.Color> {
	init(colors combined: UInt32) {
		self = [
			Element(color: DVDInfo.Reference(color: .init(combined.bits(16...19))),
			        alpha: Double(16 - combined.bits(0...3)) * 1/16),
			Element(color: DVDInfo.Reference(color: .init(combined.bits(20...23))),
			        alpha: Double(16 - combined.bits(4...7)) * 1/16),
			Element(color: DVDInfo.Reference(color: .init(combined.bits(24...27))),
			        alpha: Double(16 - combined.bits(8...11)) * 1/16),
			Element(color: DVDInfo.Reference(color: .init(combined.bits(28...31))),
			        alpha: Double(16 - combined.bits(12...15)) * 1/16)
		]
	}
}


/* MARK: Command */

private extension DVDInfo.Command {
	init(_ command: vm_cmd_t) {
		var combined: UInt64 = 0
		combined |= UInt64(command.bytes.0) << 56
		combined |= UInt64(command.bytes.1) << 48
		combined |= UInt64(command.bytes.2) << 40
		combined |= UInt64(command.bytes.3) << 32
		combined |= UInt64(command.bytes.4) << 24
		combined |= UInt64(command.bytes.5) << 16
		combined |= UInt64(command.bytes.6) <<  8
		combined |= UInt64(command.bytes.7) <<  0
		let command = combined

		let condition: Condition?
		let action: Self
		let link: Self

		switch command.bits(61...63) {
		case 0:
			// special instructions
			condition = Self.decode(conditionType1: command)
			switch command.bits(48...51) {
			case 0: action = .nop
			case 1: action = .goto(line: .init(command.bits(0...7)))
			case 2: action = .break
			case 3: action = .setParentalLevelAndGoto(level: Int(command.bits(8...11)),
			                                          line: .init(command.bits(0...7)))
			default: action = .unexpected(command)
			}
			link = .nop

		case 1:
			// link/jump/call instructions
			switch command.bit(60) {
			case false:
				condition = Self.decode(conditionType1: command)
				action = Self.decode(link: command)
			case true:
				condition = Self.decode(conditionType2: command)
				action = Self.decode(jumpOrCall: command)
			}
			link = .nop

		case 2:
			// system register set instructions
			condition = Self.decode(conditionType2: command)
			action = Self.decode(systemSet: command)
			link = Self.decode(link: command)

		case 3:
			// general purpose register calculation instructions
			condition = Self.decode(conditionType3: command)
			let lhs, rhs, swap: Operand
			lhs = .generalRegister(.init(command.bits(32...35)))
			if command.bit(60) {
				rhs = .immediate(UInt16(command.bits(16...31)))
			} else {
				rhs = Self.decode(register: UInt8(command.bits(16...23)))
			}
			swap = .generalRegister(.init(command.bits(16...19)))
			action = Self.decode(compute: command, lhs: lhs, rhs: rhs, swap: swap)
			link = Self.decode(link: command)

		case 4...6:
			// combinations of condition, calculation, and link instructions
			condition = Self.decode(conditionType4: command)
			let lhs, rhs, swap: Operand
			lhs = .generalRegister(.init(command.bits(48...51)))
			if command.bit(60) {
				rhs = .immediate(UInt16(command.bits(32...47)))
			} else {
				rhs = Self.decode(register: UInt8(command.bits(32...39)))
			}
			swap = .generalRegister(.init(command.bits(32...35)))
			action = Self.decode(compute: command, lhs: lhs, rhs: rhs, swap: swap)
			link = Self.decode(subLink: command)

		default:
			condition = nil
			action = .unexpected(command)
			link = .nop
		}

		switch (command.bits(61...63), condition, action, link) {
		case (_, _, .unexpected, _), (_, _, _, .unexpected):
			self = .unexpected(command)
		case (_, .none, _, .nop):
			self = action
		case (_, .none, .nop, _):
			self = link
		case (_, .none, _, _):
			self = .compound(action, link)
		case (_, .some, .nop, .nop):
			self = .nop

		// conditional action (link and condition cannot appear together)
		case (0...3, .some(let condition), _, .nop):
			self = .condition(if: condition, then: action)

		// unconditional action, then conditional link
		case (4, .some, _, .nop):
			self = action
		case (4, .some(let condition), .nop, _):
			self = .condition(if: condition, then: link)
		case (4, .some(let condition), _, _):
			self = .compound(action, .condition(if: condition, then: link))

		// conditional action and link
		case (5, .some(let condition), _, .nop):
			self = .condition(if: condition, then: action)
		case (5, .some(let condition), .nop, _):
			self = .condition(if: condition, then: link)
		case (5, .some(let condition), _, _):
			self = .condition(if: condition, then: .compound(action, link))

		// conditional action, then unconditional link
		case (6, .some(let condition), _, .nop):
			self = .condition(if: condition, then: action)
		case (6, .some, .nop, _):
			self = link
		case (6, .some(let condition), _, _):
			self = .compound(.condition(if: condition, then: action), link)

		default:
			self = .unexpected(command)
		}
	}

	static func decode(conditionType1 command: UInt64) -> Condition? {
		let lhs, rhs: Operand
		lhs = decode(register: UInt8(command.bits(32...39)))
		if command.bit(55) {
			rhs = .immediate(UInt16(command.bits(16...31)))
		} else {
			rhs = decode(register: UInt8(command.bits(16...23)))
		}
		return decode(condition: command, lhs: lhs, rhs: rhs)
	}
	static func decode(conditionType2 command: UInt64) -> Condition? {
		let lhs, rhs: Operand
		lhs = decode(register: UInt8(command.bits(8...15)))
		rhs = decode(register: UInt8(command.bits(0...7)))
		return decode(condition: command, lhs: lhs, rhs: rhs)
	}
	static func decode(conditionType3 command: UInt64) -> Condition? {
		let lhs, rhs: Operand
		lhs = decode(register: UInt8(command.bits(40...47)))
		if command.bit(55) {
			rhs = .immediate(UInt16(command.bits(0...15)))
		} else {
			rhs = decode(register: UInt8(command.bits(0...7)))
		}
		return decode(condition: command, lhs: lhs, rhs: rhs)
	}
	static func decode(conditionType4 command: UInt64) -> Condition? {
		let lhs, rhs: Operand
		lhs = decode(register: UInt8(command.bits(48...51)))
		if command.bit(55) {
			rhs = .immediate(UInt16(command.bits(16...31)))
		} else {
			rhs = decode(register: UInt8(command.bits(16...23)))
		}
		return decode(condition: command, lhs: lhs, rhs: rhs)
	}
	static func decode(condition command: UInt64, lhs: Operand, rhs: Operand) -> Condition? {
		switch command.bits(52...54) {
		case 1: return .bitwiseAndNotZero(lhs, rhs)
		case 2: return .equal(lhs, rhs)
		case 3: return .notEqual(lhs, rhs)
		case 4: return .greaterThanOrEqual(lhs, rhs)
		case 5: return .greaterThan(lhs, rhs)
		case 6: return .lessThanOrEqual(lhs, rhs)
		case 7: return .lessThan(lhs, rhs)
		default: return nil
		}
	}

	static func decode(register: UInt8) -> Operand {
		if register.bit(7) {
			return .systemRegister(.init(register.bits(0...6)))
		} else {
			return .generalRegister(.init(register.bits(0...6)))
		}
	}

	static func decode(link command: UInt64) -> Self {
		let button = DVDInfo.Index<DVDInfo.Interaction.Button>(command.bits(10...15))
		switch command.bits(48...51) {
		case 0: return .nop
		case 1: return decode(subLink: command)
		case 4: return .jump(to: .programChain(.init(command.bits(0...15))))
		case 5: return .jump(to: .part(.init(command.bits(0...9)), button))
		case 6: return .jump(to: .program(.init(command.bits(0...7)), button))
		case 7: return .jump(to: .cell(.init(command.bits(0...7)), button))
		default: return .unexpected(command)
		}
	}
	static func decode(subLink command: UInt64) -> Self {
		let button = DVDInfo.Index<DVDInfo.Interaction.Button>(command.bits(10...15))
		switch command.bits(0...4) {
		case 0: return .jump(to: .none(button))
		case 1: return .jump(to: .startOfCell(button))
		case 2: return .jump(to: .nextCell(button))
		case 3: return .jump(to: .previousCell(button))
		case 5: return .jump(to: .startOfProgram(button))
		case 6: return .jump(to: .nextProgram(button))
		case 7: return .jump(to: .previousProgram(button))
		case 9: return .jump(to: .startOfProgramChain(button))
		case 10: return .jump(to: .nextProgramChain(button))
		case 11: return .jump(to: .previousProgramChain(button))
		case 12: return .jump(to: .upProgramChain(button))
		case 13: return .jump(to: .endOfProgramChain(button))
		case 16: return .jump(to: .resume(button))
		default: return .unexpected(command)
		}
	}
	static func decode(jumpOrCall command: UInt64) -> Self {
		switch command.bits(48...51) {
		case 0: return .nop
		case 1: return .exit
		case 2: return .jump(to: .title(.init(command.bits(16...23))))
		case 3: return .jump(to: .titleWithinTitleSet(.init(command.bits(16...23))))
		case 5: return .jump(to: .partWithinTitleSet(.init(command.bits(16...23)),
		                                             .init(command.bits(32...40))))
		case 6:
			switch command.bits(22...23) {
			case 0: return .jump(to: .start)
			case 1: return .jump(to: .topLevelMenu(.init(UInt8(command.bits(16...19)))))
			case 2: return .jump(to: .titleMenu(.init(command.bits(24...31)),
			                                    .init(command.bits(32...39)),
			                                    .init(UInt8(command.bits(16...19)))))
			case 3: return .jump(to: .topLevelProgramChain(.init(command.bits(32...47))))
			default: return .unexpected(command)
			}
		case 8:
			let resume = DVDInfo.Index<DVDInfo.ProgramChain.Cell>(command.bits(24...31))
			switch command.bits(22...23) {
			case 0: return .call(to: .start, resume: resume)
			case 1: return .call(to: .topLevelMenu(.init(UInt8(command.bits(16...19)))), resume: resume)
			case 2: return .call(to: .menu(.init(UInt8(command.bits(16...19)))), resume: resume)
			case 3: return .call(to: .topLevelProgramChain(.init(command.bits(32...47))), resume: resume)
			default: return .unexpected(command)
			}
		default: return .unexpected(command)
		}
	}

	static func decode(systemSet command: UInt64) -> Self {
		let immediate = command.bit(60)
		var assignments: [SystemRegister: Operand] = [:]

		switch command.bits(56...59) {
		case 0:
			return .nop
		case 1:
			for register in 1...3 {
				let base = 40 - register * 8
				if command.bit(base + 7) {
					let value: Operand
					if immediate {
						value = .immediate(UInt16(command.bits(base...base+6)))
					} else {
						value = .generalRegister(.init(command.bits(base...base+3)))
					}
					assignments[SystemRegister(UInt8(register))] = value
				}
			}
			return .setSystemRegisters(assignments)
		case 2:
			let value: Operand
			if immediate {
				value = .immediate(UInt16(command.bits(32...47)))
			} else {
				value = .generalRegister(.init(command.bits(32...35)))
			}
			assignments[.navigationTimer] = value
			assignments[.programChainForTimer] = .immediate(UInt16(command.bits(16...31)))
			return .setSystemRegisters(assignments)
		case 3:
			let registerIndex = DVDInfo.Index<GeneralRegister>(command.bits(16...19))
			let counterMode = command.bit(23)
			let value: Operand
			if immediate {
				value = .immediate(UInt16(command.bits(32...47)))
			} else {
				value = .generalRegister(.init(command.bits(32...35)))
			}
			return .setGeneralRegister(registerIndex, counter: counterMode, value: value)
		case 4:
			let value: Operand
			if immediate {
				value = .immediate(UInt16(command.bits(16...31)))
			} else {
				value = .generalRegister(.init(command.bits(16...19)))
			}
			assignments[.karaokeMode] = value
			return .setSystemRegisters(assignments)
		case 6:
			let value: Operand
			if immediate {
				value = .immediate(UInt16(command.bits(16...31)))
			} else {
				value = .generalRegister(.init(command.bits(16...19)))
			}
			assignments[.selectedButtonIndex] = value
			return .setSystemRegisters(assignments)
		default:
			return .unexpected(command)
		}
	}

	static func decode(compute command: UInt64, lhs: Operand, rhs: Operand, swap: Operand) -> Self {
		switch command.bits(56...59) {
		case 0:	return .nop
		case 1: return .compute(.assign(lhs, rhs))
		case 2: return .compute(.swap(lhs, swap))
		case 3: return .compute(.add(lhs, rhs))
		case 4: return .compute(.subtract(lhs, rhs))
		case 5: return .compute(.multiply(lhs, rhs))
		case 6: return .compute(.divide(lhs, rhs))
		case 7: return .compute(.modulus(lhs, rhs))
		case 8: return .compute(.random(lhs, rhs))
		case 9: return .compute(.bitwiseAnd(lhs, rhs))
		case 10: return .compute(.bitwiseOr(lhs, rhs))
		case 11: return .compute(.bitwiseXor(lhs, rhs))
		default: return .unexpected(command)
		}
	}
}

extension DVDInfo.Command.SystemRegister {
	init(_ register: UInt8) {
		switch register {
		case 0: self = .preferredMenuLanguage
		case 1: self = .audioStreamIndex
		case 2: self = .subpictureStreamIndex
		case 3: self = .viewingAngleIndex
		case 4: self = .globalTitleIndex
		case 5: self = .titleIndex
		case 6: self = .programChainIndex
		case 7: self = .partIndex
		case 8: self = .selectedButtonIndex
		case 9: self = .navigationTimer
		case 10: self = .programChainForTimer
		case 11: self = .karaokeMode
		case 12: self = .parentalCountry
		case 13: self = .parentalLevel
		case 14: self = .videoMode
		case 15: self = .playerAudioCapabilities
		case 16: self = .preferredAudioLanguage
		case 17: self = .preferredAudioContent
		case 18: self = .preferredSubpictureLanguage
		case 19: self = .preferredSubpictureContent
		case 20: self = .playerRegionMask
		case 21...23: self = .reserved
		default: self = .unexpected
		}
	}
}


/* MARK: Restrictions */

private extension DVDInfo.Restrictions {
	init(_ ops: user_ops_t) {
		self.init()
		if ops.title_or_time_play != 0 { self.update(with: .noJumpIntoTitle) }
		if ops.chapter_search_or_play != 0 { self.update(with: .noJumpToPart) }
		if ops.title_play != 0 { self.update(with: .noJumpToTitle) }
		if ops.stop != 0 { self.update(with: .noStop) }
		if ops.go_up != 0 { self.update(with: .noJumpUp) }
		if ops.time_or_chapter_search != 0 { self.update(with: .noJumpIntoPart) }
		if ops.prev_or_top_pg_search != 0 { self.update(with: .noProgramBackward) }
		if ops.next_pg_search != 0 { self.update(with: .noProgramForward) }
		if ops.forward_scan != 0 { self.update(with: .noSeekForward) }
		if ops.backward_scan != 0 { self.update(with: .noSeekBackward) }
		if ops.title_menu_call != 0 { self.update(with: .noJumpToTopLevelMenu) }
		if ops.root_menu_call != 0 { self.update(with: .noJumpToPerTitleMenu) }
		if ops.subpic_menu_call != 0 { self.update(with: .noJumpToSubpictureMenu) }
		if ops.audio_menu_call != 0 { self.update(with: .noJumpToAudioMenu) }
		if ops.angle_menu_call != 0 { self.update(with: .noJumpToViewingAngleMenu) }
		if ops.chapter_menu_call != 0 { self.update(with: .noJumpToChapterMenu) }
		if ops.resume != 0 { self.update(with: .noResumeFromMenu) }
		if ops.button_select_or_activate != 0 { self.update(with: .noMenuInteractions) }
		if ops.still_off != 0 { self.update(with: .noStillSkip) }
		if ops.pause_on != 0 { self.update(with: .noPause) }
		if ops.audio_stream_change != 0 { self.update(with: .noChangeAudioStream) }
		if ops.subpic_stream_change != 0 { self.update(with: .noChangeSubpictureStream) }
		if ops.angle_change != 0 { self.update(with: .noChangeViewingAngle) }
		if ops.karaoke_audio_pres_mode_change != 0 { self.update(with: .noChangeKaraokeMode) }
		if ops.video_pres_mode_change != 0 { self.update(with: .noChangeVideoMode) }
	}
}


/* MARK: Helper Extensions */

private extension String {
	/// Create a `String` from two ASCII characters in a two byte integer.
	init(twoCharacters combined: UInt16) {
		self.init()
		let unicodePoint0 = Unicode.Scalar(UInt8(combined.bits(8...15)))
		let unicodePoint1 = Unicode.Scalar(UInt8(combined.bits(0...7)))
		if unicodePoint0.isASCII && unicodePoint1.isASCII {
			self.append(Character(unicodePoint0))
			self.append(Character(unicodePoint1))
		} else {
			self.append("un")
		}
	}
}

extension pgci_lu_t: Hashable {
	public func hash(into hasher: inout Hasher) {
		withUnsafeBytes(of: self) {
			hasher.combine(bytes: $0)
		}
	}
	public static func == (lhs: pgci_lu_t, rhs: pgci_lu_t) -> Bool {
		withUnsafeBytes(of: lhs) { lhs in
			withUnsafeBytes(of: rhs) { rhs in
				lhs.elementsEqual(rhs)
			}
		}
	}
}
