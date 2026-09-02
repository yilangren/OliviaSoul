param(
    [Parameter(Mandatory = $true)][string]$GameRoot,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OriginalFile,
    [string]$ServiceUrl = "http://127.0.0.1:27149"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$relative = "$Version\resources\feapp.dat"
$source = Join-Path $GameRoot $relative
$gamePrefix = [IO.Path]::GetFullPath($GameRoot).TrimEnd("\") + "\"
Get-CimInstance Win32_Process |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($gamePrefix, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 250
if (-not (Test-Path -LiteralPath $OriginalFile)) {
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($OriginalFile)) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $OriginalFile -Force
}
$buildRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\_build\feapp-local"))
$extracted = Join-Path $buildRoot "extracted"
$patched = Join-Path $buildRoot "feapp.patched.dat"

if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $extracted | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($OriginalFile, $extracted)

$mainFiles = @(Get-ChildItem -LiteralPath (Join-Path $extracted "assets") -Filter "main-*.js" -File)
if ($mainFiles.Count -ne 1) { throw "expected one main-*.js, got $($mainFiles.Count)" }

$utf8 = New-Object System.Text.UTF8Encoding $false
$mainPath = $mainFiles[0].FullName
$text = [IO.File]::ReadAllText($mainPath, $utf8)
$patchMarker = '/*OliviaSoulPatch:mail-music-v19*/'
if ($text.Contains($patchMarker)) { throw "original feapp already contains current patch" }
$text = $patchMarker + $text
$endpoints = @(
    "/signIn",
    "/getUserInfo",
    "/letter/send",
    "/letter/list",
    "/letter/detail",
    "/letter/unread_count",
    "/letter/share",
    "/letter/resend",
    "/addToPlaylist",
    "/delFromPlaylist",
    "/searchPlaylist"
)

foreach ($endpoint in $endpoints) {
    $from = '"' + $endpoint + '"'
    $to = '"' + $ServiceUrl.TrimEnd("/") + "/toy" + $endpoint + '"'
    $count = ([regex]::Matches($text, [regex]::Escape($from))).Count
    if ($count -ne 1) { throw "expected one endpoint occurrence for $endpoint, got $count" }
    $text = $text.Replace($from, $to)
}

$mailboxDisabled = 'N3=!1,Ss=!1,wa=({onComplete'
$mailboxEnabled = 'N3=!0,Ss=!1,wa=({onComplete'
$mailboxCount = ([regex]::Matches($text, [regex]::Escape($mailboxDisabled))).Count
if ($mailboxCount -ne 1) { throw "expected one disabled mailbox entry, got $mailboxCount" }
$text = $text.Replace($mailboxDisabled, $mailboxEnabled)

$offlineWidgetsDisabled = 'e.isOfflineMode&&(l.value.mailWidget!==!1&&(l.value.mailWidget=!1),l.value.musicWidget!==!1&&(l.value.musicWidget=!1))'
$offlineWidgetsEnabled = 'l.value.mailWidget=!0,l.value.musicWidget=!0'
$offlineWidgetsCount = ([regex]::Matches($text, [regex]::Escape($offlineWidgetsDisabled))).Count
if ($offlineWidgetsCount -ne 1) { throw "expected one offline widget lock, got $offlineWidgetsCount" }
$text = $text.Replace($offlineWidgetsDisabled, $offlineWidgetsEnabled)

$offlineRequestBlock = 'if(t.isOfflineMode)throw new Ol(e)'
$offlineRequestAllow = 'if(!1)throw new Ol(e)'
$offlineRequestCount = ([regex]::Matches($text, [regex]::Escape($offlineRequestBlock))).Count
if ($offlineRequestCount -ne 1) { throw "expected one offline request interceptor, got $offlineRequestCount" }
$text = $text.Replace($offlineRequestBlock, $offlineRequestAllow)

$hideWriteFrom = '"hide-write":o(p)||!o(N3)'
$hideWriteTo = '"hide-write":!1'
$hideWriteCount = ([regex]::Matches($text, [regex]::Escape($hideWriteFrom))).Count
if ($hideWriteCount -ne 1) { throw "expected one offline hide-write gate, got $hideWriteCount" }
$text = $text.Replace($hideWriteFrom, $hideWriteTo)

$mailFetchFrom = 'He(()=>{p.value||d.fetchMailList(!0)})'
$mailFetchTo = 'He(()=>{d.fetchMailList(!0)})'
$mailFetchCount = ([regex]::Matches($text, [regex]::Escape($mailFetchFrom))).Count
if ($mailFetchCount -ne 1) { throw "expected one offline mailbox fetch skip, got $mailFetchCount" }
$text = $text.Replace($mailFetchFrom, $mailFetchTo)

$offlinePollSkip = 's.isOfflineMode||(s.appMode===Se.PRO?Lt().proRestoreFromApi():s.appMode===Se.LITE&&(Lt().liteStartPoll(),uo().startPolling()))'
$offlinePollRun = 's.appMode===Se.PRO?Lt().proRestoreFromApi():s.appMode===Se.LITE&&(s.isOfflineMode?uo().startPolling():(Lt().liteStartPoll(),uo().startPolling()))'
$offlinePollCount = ([regex]::Matches($text, [regex]::Escape($offlinePollSkip))).Count
if ($offlinePollCount -ne 1) { throw "expected one offline letter polling skip, got $offlinePollCount" }
$text = $text.Replace($offlinePollSkip, $offlinePollRun)

$midiUidWatchFrom = 'X&&(t.value===Se.PRO?T():J())'
$midiUidWatchTo = 'X&&(t.value===Se.PRO?T():Ie().isOfflineMode||J())'
$midiUidWatchCount = ([regex]::Matches($text, [regex]::Escape($midiUidWatchFrom))).Count
if ($midiUidWatchCount -ne 1) { throw "expected one midi uid watcher, got $midiUidWatchCount" }
$text = $text.Replace($midiUidWatchFrom, $midiUidWatchTo)

$midiListFrom = 'C=async()=>{try{const X=await ds({pageSize:S});E.value=X.list.map(te=>({jobId:te.jobId'
$midiListTo = 'C=async()=>{try{const X=await ds({pageSize:S},{hideToast:!0});E.value=X.list.map(te=>({jobId:te.jobId'
$midiListCount = ([regex]::Matches($text, [regex]::Escape($midiListFrom))).Count
if ($midiListCount -ne 1) { throw "expected one midi listJobs fetch, got $midiListCount" }
$text = $text.Replace($midiListFrom, $midiListTo)

$midiJobsFrom = 'async function ds(e,t){return Te.get("/midi/listJobs",{params:e,...t}).then(s=>s.data)}'
$midiJobsTo = 'async function ds(e,t){if(Ie().isOfflineMode)return{list:[],hasMore:!1,nextCursor:0,total:0};return Te.get("/midi/listJobs",{params:e,...t}).then(s=>s.data)}'
$midiJobsCount = ([regex]::Matches($text, [regex]::Escape($midiJobsFrom))).Count
if ($midiJobsCount -ne 1) { throw "expected one midi listJobs client wrapper, got $midiJobsCount" }
$text = $text.Replace($midiJobsFrom, $midiJobsTo)

$userSongsFrom = 'async function dm(e,t){return Te.get("/searchUserSongs",{params:e,...t}).then(s=>({...s.data,list:(s.data.list??[]).map(i=>{const l=i;return{...l,id:l.userSongId}})}))}'
$userSongsTo = 'async function dm(e,t){if(Ie().isOfflineMode)return{list:[],hasMore:!1,nextCursor:0,total:0};return Te.get("/searchUserSongs",{params:e,...t}).then(s=>({...s.data,list:(s.data.list??[]).map(i=>{const l=i;return{...l,id:l.userSongId}})}))}'
$userSongsCount = ([regex]::Matches($text, [regex]::Escape($userSongsFrom))).Count
if ($userSongsCount -ne 1) { throw "expected one searchUserSongs client wrapper, got $userSongsCount" }
$text = $text.Replace($userSongsFrom, $userSongsTo)

$musicFeaturesDisabled = 'N3=!0,Ss=!1,wa=({onComplete'
$musicFeaturesEnabled = 'N3=!0,Ss=!0,wa=({onComplete'
$musicFeaturesCount = ([regex]::Matches($text, [regex]::Escape($musicFeaturesDisabled))).Count
if ($musicFeaturesCount -ne 1) { throw "expected one disabled music feature gate, got $musicFeaturesCount" }
$text = $text.Replace($musicFeaturesDisabled, $musicFeaturesEnabled)

$playlistHidden = 'o(w)?Y("",!0):(r(),_(se,{key:0},[o(a)?(r(),_("div",c4,'
$playlistShown = '(r(),_(se,{key:0},[o(a)?(r(),_("div",c4,'
$playlistCount = ([regex]::Matches($text, [regex]::Escape($playlistHidden))).Count
if ($playlistCount -ne 1) { throw "expected one offline playlist hide, got $playlistCount" }
$text = $text.Replace($playlistHidden, $playlistShown)

$hideActionsFrom = '"hide-actions":o(w)'
$hideActionsTo = '"hide-actions":!1'
$hideActionsCount = ([regex]::Matches($text, [regex]::Escape($hideActionsFrom))).Count
if ($hideActionsCount -ne 1) { throw "expected one offline song action hide, got $hideActionsCount" }
$text = $text.Replace($hideActionsFrom, $hideActionsTo)

$playerOfflineHide = 'o(t)?Y("",!0):'
$playerOfflineCount = ([regex]::Matches($text, [regex]::Escape($playerOfflineHide))).Count
if ($playerOfflineCount -ne 4) { throw "expected four offline player control hides, got $playerOfflineCount" }
$text = $text.Replace($playerOfflineHide, "")

$videoReplyFrom = 'content:e.replyText??"",type:Wn(e.replyType,e.letterStatus,e.auditStatus),replyType:e.replyType,videoUrl:e.replyVideoUrl||void 0'
$videoReplyTo = 'content:e.replyText??"",type:e.letterStatus===bt.FAILED?Wn(e.replyType,e.letterStatus,e.auditStatus):e.replyVideoUrl?"video":"text",replyType:e.replyType,videoUrl:e.replyVideoUrl||void 0'
$videoReplyCount = ([regex]::Matches($text, [regex]::Escape($videoReplyFrom))).Count
if ($videoReplyCount -ne 1) { throw "expected one reply video mapping, got $videoReplyCount" }
$text = $text.Replace($videoReplyFrom, $videoReplyTo)

$startupUser = 'if(E.value){await z();return}if(!T.value){s.replace({name:ve.Login});return}const oe=await Dn({hideToast:!0,loading:!0}),{status:Ce,modelGatewayToken:Fe}=oe;oe.userInfo&&Ie().setUserProfile(oe.userInfo),P.value'
$offlineUser = 'if(E.value){try{const oe=await Dn({hideToast:!0});l.setUid(!oe.uid||String(oe.uid)==="0"?"":String(oe.uid)),oe.userInfo&&Ie().setUserProfile(oe.userInfo)}catch(_oe){}await z();return}if(!T.value){s.replace({name:ve.Login});return}const oe=await Dn({hideToast:!0,loading:!0}),{status:Ce,modelGatewayToken:Fe}=oe;l.setUid(!oe.uid||String(oe.uid)==="0"?"":String(oe.uid)),oe.userInfo&&Ie().setUserProfile(oe.userInfo),P.value'
$startupUserCount = ([regex]::Matches($text, [regex]::Escape($startupUser))).Count
if ($startupUserCount -ne 1) { throw "expected one startup user mapping, got $startupUserCount" }
$text = $text.Replace($startupUser, $offlineUser)

$pollingLoop = 'for(const re of ue){const ye=t.value.findIndex'
$orderedPollingLoop = 'for(const re of [...ue].reverse()){const ye=t.value.findIndex'
$pollingLoopCount = ([regex]::Matches($text, [regex]::Escape($pollingLoop))).Count
if ($pollingLoopCount -ne 1) { throw "expected one mailbox polling loop, got $pollingLoopCount" }
$text = $text.Replace($pollingLoop, $orderedPollingLoop)

$pollingStateFrom = '(((B=re.received)==null?void 0:B.type)!==((K=Ee.received)==null?void 0:K.type)||re.isUnread!==Ee.isUnread)&&'
$pollingStateTo = '(((B=re.received)==null?void 0:B.type)!==((K=Ee.received)==null?void 0:K.type)||re.isUnread!==Ee.isUnread||re.letterStatus!==Ee.letterStatus)&&'
$pollingStateCount = ([regex]::Matches($text, [regex]::Escape($pollingStateFrom))).Count
if ($pollingStateCount -ne 1) { throw "expected one mailbox polling state condition, got $pollingStateCount" }
$text = $text.Replace($pollingStateFrom, $pollingStateTo)

$processingIconFrom = 'const m=s.mail.id===ro,u=!s.mail.received,p=s.mail.isUnread,d=(h=s.mail.received)==null?void 0:h.type;return'
$processingIconTo = 'const m=s.mail.id===ro,u=!s.mail.received||s.mail.letterStatus===bt.LLM_PROCESSING,p=s.mail.isUnread,d=(h=s.mail.received)==null?void 0:h.type;return'
$processingIconCount = ([regex]::Matches($text, [regex]::Escape($processingIconFrom))).Count
if ($processingIconCount -ne 1) { throw "expected one processing icon condition, got $processingIconCount" }
$text = $text.Replace($processingIconFrom, $processingIconTo)

$replyIcon = 'iconType:u?"send":d==="video"?"video":"book",iconClass:u?"text-[#EFEAE3]":"text-[#E7F1F4]",iconBgClass:u?"bg-[#6B645B]":d==="video"?"bg-[#3F5F6B]":"bg-[#4F6F5E]"'
$replyIconCount = ([regex]::Matches($text, [regex]::Escape($replyIcon))).Count
if ($replyIconCount -ne 1) { throw "expected one reply icon mapping, got $replyIconCount" }

$playlistUrl = $ServiceUrl.TrimEnd("/") + "/toy/addToPlaylist"
$addPlaylistFrom = 'async function An(e,t){return Te.post("' + $playlistUrl + '",{itemType:e.itemType,itemId:e.itemId},t).then(s=>{const i=s.data;return{...i,itemId:i.itemId,performanceId:i.performanceId??"",songId:i.songId??"",id:i.itemId}})}'
$addPlaylistTo = 'async function An(e,t){return Te.post("' + $playlistUrl + '",{itemType:e.itemType,itemId:e.itemId??e.id??e.songId??e.performanceId,name:e.name,nameKey:e.nameKey,iconUrl:e.iconUrl??e.coverUrl,songId:e.songId,performanceId:e.performanceId,duration:e.duration??e.videoDuration??e.audioDuration,videoDuration:e.videoDuration??e.duration,videoUrl:e.videoUrl??e.mediaUrl,videoByTodView:e.videoByTodView,performanceType:e.performanceType},t).then(s=>{const i=s&&s.data&&typeof s.data=="object"?s.data:s||{};const l=i.itemId??i.item_id??e.itemId??e.id??"";return{...i,itemId:l,performanceId:i.performanceId??i.performance_id??"",songId:i.songId??i.song_id??"",id:l,duration:i.duration??i.videoDuration??e.duration??0,videoDuration:i.videoDuration??i.duration??e.videoDuration??e.duration??0,videoUrl:i.videoUrl??i.video_url??e.videoUrl??e.mediaUrl??"",coverUrl:i.coverUrl??i.iconUrl??e.coverUrl??e.iconUrl??"",performanceType:i.performanceType??e.performanceType??"",videoByTodView:e.videoByTodView??i.videoByTodView}})}'
$addPlaylistCount = ([regex]::Matches($text, [regex]::Escape($addPlaylistFrom))).Count
if ($addPlaylistCount -ne 1) { throw "expected one addToPlaylist client wrapper, got $addPlaylistCount" }
$text = $text.Replace($addPlaylistFrom, $addPlaylistTo)

$addPlaylistCallFrom = 'Pa=async(q,me)=>{const Be=await An({itemType:me,itemId:q.id});re(Be),Z.musicPlaylistAdd('
$addPlaylistCallTo = 'Pa=async(q,me)=>{const Be=await An({itemType:me,itemId:q.id||q.songId||q.itemId,name:q.name,nameKey:q.nameKey,iconUrl:q.iconUrl||q.coverUrl,songId:q.songId,performanceId:q.performanceId,duration:q.duration??q.videoDuration??q.audioDuration,videoDuration:q.videoDuration??q.duration,videoUrl:q.videoUrl||q.mediaUrl,videoByTodView:q.videoByTodView,performanceType:q.performanceType});re(Be),Z.musicPlaylistAdd('
$addPlaylistCallCount = ([regex]::Matches($text, [regex]::Escape($addPlaylistCallFrom))).Count
if ($addPlaylistCallCount -ne 1) { throw "expected one StudioLite add-playlist call, got $addPlaylistCallCount" }
$text = $text.Replace($addPlaylistCallFrom, $addPlaylistCallTo)

$collectionAddFrom = 'const G=async C=>{const D=await An({itemType:pt.PERFORMANCE,itemId:C.performanceId});'
$collectionAddTo = 'const G=async C=>{const D=await An({itemType:pt.PERFORMANCE,itemId:C.performanceId||C.id,name:C.performanceName||C.name,nameKey:C.songNameKey||C.nameKey,iconUrl:C.iconUrl||C.coverUrl,performanceId:C.performanceId,songId:C.songId,duration:C.duration??C.videoDuration??C.audioDuration,videoDuration:C.videoDuration??C.duration,videoUrl:C.videoUrl||C.mediaUrl,videoByTodView:C.videoByTodView,performanceType:C.performanceType});'
$collectionAddCount = ([regex]::Matches($text, [regex]::Escape($collectionAddFrom))).Count
if ($collectionAddCount -ne 1) { throw "expected one Collection add-playlist call, got $collectionAddCount" }
$text = $text.Replace($collectionAddFrom, $collectionAddTo)

$offlineUidFallbackFrom = 'const M=s.uid||b1;s.setUid(M)'
$offlineUidFallbackTo = 'const M=!s.uid||String(s.uid)==="0"?"0":String(s.uid);s.setUid(M==="0"?"":M)'
$offlineUidFallbackCount = ([regex]::Matches($text, [regex]::Escape($offlineUidFallbackFrom))).Count
if ($offlineUidFallbackCount -ne 1) { throw "expected one offline uid 10000 fallback, got $offlineUidFallbackCount" }
$text = $text.Replace($offlineUidFallbackFrom, $offlineUidFallbackTo)

$uidStoreFrom = 'E=J=>{y.value=J,Me.setCommonValues({"x-uid":J})}'
$uidStoreTo = 'E=J=>{const N=!J||String(J)==="0"?"":String(J);y.value=N,Me.setCommonValues({"x-uid":N||"0"})}'
$uidStoreCount = ([regex]::Matches($text, [regex]::Escape($uidStoreFrom))).Count
if ($uidStoreCount -ne 1) { throw "expected one setUid store assignment, got $uidStoreCount" }
$text = $text.Replace($uidStoreFrom, $uidStoreTo)

$nativeUidFrom = 'h=async(M,A,G)=>{r1({uid:M});const z=await Ym({uid:M,gwToken:A,newUser:G||void 0,level:s.appMode});'
$nativeUidTo = 'h=async(M,A,G)=>{const U=!M||String(M)==="0"?"0":String(M);r1({uid:U});const z=await Ym({uid:U,gwToken:A,newUser:G||void 0,level:s.appMode});'
$nativeUidCount = ([regex]::Matches($text, [regex]::Escape($nativeUidFrom))).Count
if ($nativeUidCount -ne 1) { throw "expected one native startClientApp uid call, got $nativeUidCount" }
$text = $text.Replace($nativeUidFrom, $nativeUidTo)

$watermarkHideFrom = 'if(!t.uid)return"none";const i=document.createElement("canvas")'
$watermarkHideTo = 'if(!t.uid||String(t.uid)==="0")return"none";const i=document.createElement("canvas")'
$watermarkHideCount = ([regex]::Matches($text, [regex]::Escape($watermarkHideFrom))).Count
if ($watermarkHideCount -ne 1) { throw "expected one watermark empty-uid skip, got $watermarkHideCount" }
$text = $text.Replace($watermarkHideFrom, $watermarkHideTo)

$watermarkMountFrom = 'o(T)?(r(),F(ye,{key:0,uid:o(T)},null,8,["uid"])):Y("",!0)'
$watermarkMountTo = '!o(T)||String(o(T))==="0"?Y("",!0):(r(),F(ye,{key:0,uid:o(T)},null,8,["uid"]))'
$watermarkMountCount = ([regex]::Matches($text, [regex]::Escape($watermarkMountFrom))).Count
if ($watermarkMountCount -ne 1) { throw "expected one watermark overlay mount, got $watermarkMountCount" }
$text = $text.Replace($watermarkMountFrom, $watermarkMountTo)

$watermarkStyleFrom = 'return(i,l)=>(r(),_("div",{class:"watermark-overlay",style:Ae({backgroundImage:o(s)})},null,4))'
$watermarkStyleTo = 'return(i,l)=>(r(),_("div",{class:"watermark-overlay",style:Ae({backgroundImage:o(s),display:!t.uid||String(t.uid)==="0"?"none":void 0})},null,4))'
$watermarkStyleCount = ([regex]::Matches($text, [regex]::Escape($watermarkStyleFrom))).Count
if ($watermarkStyleCount -ne 1) { throw "expected one watermark overlay style, got $watermarkStyleCount" }
$text = $text.Replace($watermarkStyleFrom, $watermarkStyleTo)

$midiCardFrom = '!o(w)&&o(Ss)?'
$midiCardTo = 'o(Ss)?'
$midiCardCount = ([regex]::Matches($text, [regex]::Escape($midiCardFrom))).Count
if ($midiCardCount -ne 1) { throw "expected one offline midi upload card hide, got $midiCardCount" }
$text = $text.Replace($midiCardFrom, $midiCardTo)

$uploadTabFrom = 'o(w)?Y("",!0):(r(),F(on,{key:0,index:so,class:"h-fit"},{default:V(()=>[n("div",Y3,v(o(t)("studio_user_upload_tab")),1)]),_:1}))'
$uploadTabTo = '(r(),F(on,{key:0,index:so,class:"h-fit"},{default:V(()=>[n("div",Y3,v(o(t)("studio_user_upload_tab")),1)]),_:1}))'
$uploadTabCount = ([regex]::Matches($text, [regex]::Escape($uploadTabFrom))).Count
if ($uploadTabCount -ne 1) { throw "expected one offline user-upload tab hide, got $uploadTabCount" }
$text = $text.Replace($uploadTabFrom, $uploadTabTo)

$menuBarFrom = '!o(w)||o(D).length>0?(r(),_("section",H3,[k(Va,{mode:"horizontal"'
$menuBarTo = '!0?(r(),_("section",H3,[k(Va,{mode:"horizontal"'
$menuBarCount = ([regex]::Matches($text, [regex]::Escape($menuBarFrom))).Count
if ($menuBarCount -ne 1) { throw "expected one offline music menu bar hide, got $menuBarCount" }
$text = $text.Replace($menuBarFrom, $menuBarTo)

$ugcListFrom = 'Ce=j(()=>w.value?oe.getSongsByStyle(R.value).filter(q=>f.isDownloaded(q.id)):Q.value?te.value:N.value)'
$ugcListTo = 'Ce=j(()=>Q.value?te.value:w.value?oe.getSongsByStyle(R.value).filter(q=>f.isDownloaded(q.id)):N.value)'
$ugcListCount = ([regex]::Matches($text, [regex]::Escape($ugcListFrom))).Count
if ($ugcListCount -ne 1) { throw "expected one offline ugc tab song-list skip, got $ugcListCount" }
$text = $text.Replace($ugcListFrom, $ugcListTo)

$uploadTabFetchFrom = 'P=async()=>{J.value=so,l.value=!0;const q=T();$e(),await xe(),!(q!==c||!Q.value)&&(l.value=!1,await qe(),X(eo(ct.value)))}'
$uploadTabFetchTo = 'P=async()=>{J.value=so,l.value=!0;const q=T();$e();if(w.value){l.value=!1;return}await xe(),!(q!==c||!Q.value)&&(l.value=!1,await qe(),X(eo(ct.value)))}'
$uploadTabFetchCount = ([regex]::Matches($text, [regex]::Escape($uploadTabFetchFrom))).Count
if ($uploadTabFetchCount -ne 1) { throw "expected one user-upload tab remote fetch, got $uploadTabFetchCount" }
$text = $text.Replace($uploadTabFetchFrom, $uploadTabFetchTo)

$offlinePlaylistSkip = 'He(async()=>{if(w.value){a.value=!1;return}await Ua(),await W().finally(()=>{a.value=!1}),Po()});'
$offlinePlaylistFetch = 'He(async()=>{if(w.value){await W().finally(()=>{a.value=!1}),Po();return}await Ua(),await W().finally(()=>{a.value=!1}),Po()});'
$offlinePlaylistCount = ([regex]::Matches($text, [regex]::Escape($offlinePlaylistSkip))).Count
if ($offlinePlaylistCount -ne 1) { throw "expected one offline playlist fetch skip, got $offlinePlaylistCount" }
$text = $text.Replace($offlinePlaylistSkip, $offlinePlaylistFetch)

[IO.File]::WriteAllText($mainPath, $text, $utf8)

$archiveStream = [IO.File]::Open($patched, [IO.FileMode]::Create)
$archive = New-Object -TypeName IO.Compression.ZipArchive -ArgumentList @(
    $archiveStream,
    [IO.Compression.ZipArchiveMode]::Create,
    $false
)
try {
    foreach ($file in Get-ChildItem -LiteralPath $extracted -File -Recurse) {
        $entryName = $file.FullName.Substring($extracted.Length + 1).Replace("\", "/")
        $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
        $input = [IO.File]::OpenRead($file.FullName)
        $output = $entry.Open()
        try {
            $input.CopyTo($output)
        }
        finally {
            $output.Dispose()
            $input.Dispose()
        }
    }
}
finally {
    $archive.Dispose()
    $archiveStream.Dispose()
}
Copy-Item -LiteralPath $patched -Destination $source -Force

$verifyDir = Join-Path $buildRoot "verify"
New-Item -ItemType Directory -Path $verifyDir | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($source, $verifyDir)
$verifyMain = @(Get-ChildItem -LiteralPath (Join-Path $verifyDir "assets") -Filter "main-*.js" -File)[0]
$verifyText = [IO.File]::ReadAllText($verifyMain.FullName, $utf8)
foreach ($endpoint in $endpoints) {
    $expected = $ServiceUrl.TrimEnd("/") + "/toy" + $endpoint
    if (-not $verifyText.Contains($expected)) { throw "patched archive missing $expected" }
}
if (-not $verifyText.StartsWith($patchMarker)) { throw "patched archive missing revision marker" }
if (-not $verifyText.Contains($offlineWidgetsEnabled)) { throw "patched archive still disables offline desktop widgets" }
if (-not $verifyText.Contains($musicFeaturesEnabled)) { throw "patched archive still has mailbox or music features disabled" }
if (-not $verifyText.Contains($playlistShown)) { throw "patched archive still hides the offline playlist" }
if (-not $verifyText.Contains($hideActionsTo)) { throw "patched archive still hides offline song actions" }
if (-not $verifyText.Contains($offlineRequestAllow)) { throw "patched archive still blocks offline HTTP requests" }
if (-not $verifyText.Contains($hideWriteTo)) { throw "patched archive still hides the write-letter entry" }
if (-not $verifyText.Contains($mailFetchTo)) { throw "patched archive still skips offline mailbox fetch" }
if (-not $verifyText.Contains($offlinePollRun)) { throw "patched archive still skips offline letter polling" }
if ($verifyText.Contains('s.appMode===Se.PRO?Lt().proRestoreFromApi():s.appMode===Se.LITE&&(Lt().liteStartPoll(),uo().startPolling())')) { throw "patched archive still starts midi poll while offline" }
if (-not $verifyText.Contains($midiUidWatchTo)) { throw "patched archive still starts midi poll from uid watcher while offline" }
if ($verifyText.Contains($midiUidWatchFrom)) { throw "patched archive still has the original midi uid watcher" }
if (-not $verifyText.Contains($midiListTo)) { throw "patched archive missing midi listJobs hideToast" }
if ($verifyText.Contains($midiListFrom)) { throw "patched archive still toasts midi listJobs errors" }
if (-not $verifyText.Contains($midiJobsTo) -or $verifyText.Contains($midiJobsFrom)) { throw "patched archive still polls midi listJobs while offline" }
if (-not $verifyText.Contains($userSongsTo) -or $verifyText.Contains($userSongsFrom)) { throw "patched archive still fetches searchUserSongs while offline" }
if (-not $verifyText.Contains($videoReplyTo)) { throw "patched archive missing exclusive video reply mapping" }
if (-not $verifyText.Contains($offlineUser)) { throw "patched archive missing offline uid synchronization" }
if (-not $verifyText.Contains($offlineUidFallbackTo)) { throw "patched archive still falls back to uid 10000" }
if ($verifyText.Contains($offlineUidFallbackFrom)) { throw "patched archive still has the original uid 10000 fallback" }
if (-not $verifyText.Contains($uidStoreTo) -or $verifyText.Contains($uidStoreFrom)) { throw "patched archive still stores uid 0 for watermark" }
if (-not $verifyText.Contains($nativeUidTo) -or $verifyText.Contains($nativeUidFrom)) { throw "patched archive still passes empty uid to native login" }
if (-not $verifyText.Contains($watermarkHideTo) -or $verifyText.Contains($watermarkHideFrom)) { throw "patched archive still draws watermark for uid 0" }
if (-not $verifyText.Contains($watermarkMountTo) -or $verifyText.Contains($watermarkMountFrom)) { throw "patched archive still mounts watermark overlay for uid 0" }
if (-not $verifyText.Contains($watermarkStyleTo) -or $verifyText.Contains($watermarkStyleFrom)) { throw "patched archive still shows watermark overlay for uid 0" }
if (-not $verifyText.Contains($midiCardTo) -or $verifyText.Contains($midiCardFrom)) { throw "patched archive still hides the offline midi upload card" }
if (-not $verifyText.Contains($uploadTabTo) -or $verifyText.Contains($uploadTabFrom)) { throw "patched archive still hides the user-upload tab" }
if (-not $verifyText.Contains($menuBarTo) -or $verifyText.Contains($menuBarFrom)) { throw "patched archive still hides the offline music menu bar" }
if (-not $verifyText.Contains($ugcListTo) -or $verifyText.Contains($ugcListFrom)) { throw "patched archive still skips offline ugc song list" }
if (-not $verifyText.Contains($orderedPollingLoop)) { throw "patched archive missing mailbox polling order fix" }
if (-not $verifyText.Contains($pollingStateTo)) { throw "patched archive missing polling status comparison" }
if (-not $verifyText.Contains($processingIconTo)) { throw "patched archive missing processing envelope icon condition" }
if (-not $verifyText.Contains($replyIcon)) { throw "patched archive missing reply icon mapping" }
if ($verifyText.Contains($playerOfflineHide)) { throw "patched archive still hides offline player controls" }
if (-not $verifyText.Contains($addPlaylistTo)) { throw "patched archive missing add-playlist client unwrap fix" }
if (-not $verifyText.Contains($addPlaylistCallTo)) { throw "patched archive missing StudioLite add-playlist payload fix" }
if (-not $verifyText.Contains($collectionAddTo)) { throw "patched archive missing Collection add-playlist payload fix" }
if (-not $verifyText.Contains($offlinePlaylistFetch)) { throw "patched archive still skips offline playlist fetch" }
if ($verifyText.Contains($offlinePlaylistSkip)) { throw "patched archive still has the original offline playlist fetch skip" }
if (-not $verifyText.Contains($uploadTabFetchTo) -or $verifyText.Contains($uploadTabFetchFrom)) { throw "patched archive still fetches remote songs on the user-upload tab while offline" }

$webplayerLive = Join-Path $GameRoot "$Version\resources\webplayer.dat"
if (-not (Test-Path -LiteralPath $webplayerLive)) { throw "webplayer.dat not found" }
$webplayerBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("webplayer-" + $Version + ".dat")
$webplayerBuild = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\_build\webplayer-local"))
$webplayerExtracted = Join-Path $webplayerBuild "extracted"
$webplayerPatched = Join-Path $webplayerBuild "webplayer.patched.dat"
$webplayerMarker = '/*OliviaSoulPatch:webplayer-wm-v19*/'
if (Test-Path -LiteralPath $webplayerBuild) {
    Remove-Item -LiteralPath $webplayerBuild -Recurse -Force
}
if (-not (Test-Path -LiteralPath $webplayerBackup)) {
    Copy-Item -LiteralPath $webplayerLive -Destination $webplayerBackup -Force
}
New-Item -ItemType Directory -Path $webplayerExtracted | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($webplayerBackup, $webplayerExtracted)
$webplayerMainFiles = @(Get-ChildItem -LiteralPath (Join-Path $webplayerExtracted "assets") -Filter "main-*.js" -File)
if ($webplayerMainFiles.Count -ne 1) { throw "expected one webplayer main-*.js, got $($webplayerMainFiles.Count)" }
$webplayerMainPath = $webplayerMainFiles[0].FullName
$webplayerText = [IO.File]::ReadAllText($webplayerMainPath, $utf8)
if ($webplayerText.Contains($webplayerMarker) -or $webplayerText.Contains("OliviaSoulPatch:")) { throw "original webplayer backup already contains a patch" }
$wpUidFrom = 'const n=new URLSearchParams(window.location.search).get("uid")||"unknown"'
$wpUidTo = 'const n=function(){var q=new URLSearchParams(window.location.search).get("uid");return!q||q==="0"?"":q}()'
$wpUidCount = ([regex]::Matches($webplayerText, [regex]::Escape($wpUidFrom))).Count
if ($wpUidCount -ne 1) { throw "expected one webplayer uid query fallback, got $wpUidCount" }
$webplayerText = $webplayerText.Replace($wpUidFrom, $wpUidTo)
$wpHideFrom = 'if(!n.uid)return"none";const r=document.createElement("canvas")'
$wpHideTo = 'if(!n.uid||String(n.uid)==="0")return"none";const r=document.createElement("canvas")'
$wpHideCount = ([regex]::Matches($webplayerText, [regex]::Escape($wpHideFrom))).Count
if ($wpHideCount -ne 1) { throw "expected one webplayer watermark empty-uid skip, got $wpHideCount" }
$webplayerText = $webplayerText.Replace($wpHideFrom, $wpHideTo)
$wpMountFrom = 'S(n)?(k(),we(l,{key:0,uid:S(n)},null,8,["uid"])):Re("",!0)'
$wpMountTo = '!S(n)||String(S(n))==="0"?Re("",!0):(k(),we(l,{key:0,uid:S(n)},null,8,["uid"]))'
$wpMountCount = ([regex]::Matches($webplayerText, [regex]::Escape($wpMountFrom))).Count
if ($wpMountCount -ne 1) { throw "expected one webplayer watermark overlay mount, got $wpMountCount" }
$webplayerText = $webplayerText.Replace($wpMountFrom, $wpMountTo)
$wpStyleFrom = 'return(r,a)=>(k(),I("div",{class:"watermark-overlay",style:he({backgroundImage:S(s)})},null,4))'
$wpStyleTo = 'return(r,a)=>(k(),I("div",{class:"watermark-overlay",style:he({backgroundImage:S(s),display:!n.uid||String(n.uid)==="0"?"none":void 0})},null,4))'
$wpStyleCount = ([regex]::Matches($webplayerText, [regex]::Escape($wpStyleFrom))).Count
if ($wpStyleCount -ne 1) { throw "expected one webplayer watermark overlay style, got $wpStyleCount" }
$webplayerText = $webplayerText.Replace($wpStyleFrom, $wpStyleTo)
$webplayerText = $webplayerMarker + $webplayerText
[IO.File]::WriteAllText($webplayerMainPath, $webplayerText, $utf8)

$webplayerHtmlPath = Join-Path $webplayerExtracted "index.html"
if (-not (Test-Path -LiteralPath $webplayerHtmlPath)) { throw "webplayer index.html not found" }
$webplayerHtml = [IO.File]::ReadAllText($webplayerHtmlPath, $utf8)
$wpHtmlFrom = "  <link rel=`"stylesheet`" href=`"./assets/vendor-element-7c8f0743.css`">`n</head>"
$wpHtmlTo = "  <link rel=`"stylesheet`" href=`"./assets/vendor-element-7c8f0743.css`">`n<style>`n.watermark-overlay {`ndisplay: none !important;`n}`n</style>`n<script>(function(){var u=new URLSearchParams(location.search).get('uid');if(u&&u!=='0'){var s=document.currentScript&&document.currentScript.previousElementSibling;if(s&&s.tagName==='STYLE')s.remove();}})();</script>`n</head>"
$wpHtmlCount = ([regex]::Matches($webplayerHtml, [regex]::Escape($wpHtmlFrom))).Count
if ($wpHtmlCount -ne 1) { throw "expected one webplayer head stylesheet close, got $wpHtmlCount" }
$webplayerHtml = $webplayerHtml.Replace($wpHtmlFrom, $wpHtmlTo)
[IO.File]::WriteAllText($webplayerHtmlPath, $webplayerHtml, $utf8)

$webplayerStream = [IO.File]::Open($webplayerPatched, [IO.FileMode]::Create)
$webplayerArchive = New-Object -TypeName IO.Compression.ZipArchive -ArgumentList @(
    $webplayerStream,
    [IO.Compression.ZipArchiveMode]::Create,
    $false
)
try {
    foreach ($file in Get-ChildItem -LiteralPath $webplayerExtracted -File -Recurse) {
        $entryName = $file.FullName.Substring($webplayerExtracted.Length + 1).Replace("\", "/")
        $entry = $webplayerArchive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
        $input = [IO.File]::OpenRead($file.FullName)
        $output = $entry.Open()
        try {
            $input.CopyTo($output)
        }
        finally {
            $output.Dispose()
            $input.Dispose()
        }
    }
}
finally {
    $webplayerArchive.Dispose()
    $webplayerStream.Dispose()
}
Copy-Item -LiteralPath $webplayerPatched -Destination $webplayerLive -Force

$webplayerVerifyDir = Join-Path $webplayerBuild "verify"
New-Item -ItemType Directory -Path $webplayerVerifyDir | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($webplayerLive, $webplayerVerifyDir)
$webplayerVerifyMain = @(Get-ChildItem -LiteralPath (Join-Path $webplayerVerifyDir "assets") -Filter "main-*.js" -File)[0]
$webplayerVerifyText = [IO.File]::ReadAllText($webplayerVerifyMain.FullName, $utf8)
$webplayerVerifyHtml = [IO.File]::ReadAllText((Join-Path $webplayerVerifyDir "index.html"), $utf8)
if (-not $webplayerVerifyText.StartsWith($webplayerMarker)) { throw "patched webplayer missing revision marker" }
if (-not $webplayerVerifyText.Contains($wpUidTo) -or $webplayerVerifyText.Contains($wpUidFrom)) { throw "patched webplayer still draws uid 0 from the query string" }
if (-not $webplayerVerifyText.Contains($wpHideTo) -or $webplayerVerifyText.Contains($wpHideFrom)) { throw "patched webplayer still draws watermark for uid 0" }
if (-not $webplayerVerifyText.Contains($wpMountTo) -or $webplayerVerifyText.Contains($wpMountFrom)) { throw "patched webplayer still mounts watermark overlay for uid 0" }
if (-not $webplayerVerifyText.Contains($wpStyleTo) -or $webplayerVerifyText.Contains($wpStyleFrom)) { throw "patched webplayer still shows watermark overlay for uid 0" }
if (-not $webplayerVerifyHtml.Contains(".watermark-overlay {") -or -not $webplayerVerifyHtml.Contains("display: none !important;")) { throw "patched webplayer missing watermark CSS hide" }
$verifyNames = @(Get-ChildItem -LiteralPath $webplayerVerifyDir -File -Recurse | ForEach-Object { $_.FullName.Substring($webplayerVerifyDir.Length + 1).Replace("\", "/") })
if ($verifyNames -notcontains "index.html") { throw "patched webplayer zip wrapped an extra folder" }

$latin1 = [Text.Encoding]::GetEncoding(28591)
function Find-ByteSequence([byte[]]$Haystack, [byte[]]$Needle) {
    return $latin1.GetString($Haystack).IndexOf($latin1.GetString($Needle))
}

$nutBasePath = Join-Path $GameRoot "$Version\NutBase.dll"
$nutBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("NutBase-" + $Version + ".dll")
if ((Test-Path -LiteralPath $nutBackup) -and (Test-Path -LiteralPath $nutBasePath)) {
    Copy-Item -LiteralPath $nutBackup -Destination $nutBasePath -Force
}

$studioUiPath = Join-Path $GameRoot "$Version\plugins\Studio\NutStudioUI.dll"
if (-not (Test-Path -LiteralPath $studioUiPath)) { throw "NutStudioUI.dll not found: $studioUiPath" }
$studioBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("NutStudioUI-" + $Version + ".dll")
$offlineCallFrom = @(
    [byte[]](0xCB, 0xE8, 0xD2, 0x37, 0x08, 0x00, 0xEB, 0x1E, 0xFF, 0x15, 0xB2, 0xEC, 0x08, 0x00, 0x48, 0x8D, 0x8F, 0xA8),
    [byte[]](0xCB, 0xE8, 0x72, 0x34, 0x08, 0x00, 0xEB, 0x1E, 0xFF, 0x15, 0x52, 0xE9, 0x08, 0x00, 0x48, 0x8D, 0x8F, 0xA8),
    [byte[]](0xCB, 0xE8, 0xB2, 0x1F, 0x08, 0x00, 0xEB, 0x2B, 0xFF, 0x15, 0x92, 0xD4, 0x08, 0x00, 0x84, 0xC0, 0x75, 0x14),
    [byte[]](0xCB, 0xE8, 0xFF, 0x1D, 0x08, 0x00, 0xEB, 0x1C, 0xFF, 0x15, 0xDF, 0xD2, 0x08, 0x00, 0x48, 0x8D, 0x4F, 0x38)
)
$offlineCallPatch = [byte[]](0x33, 0xC0, 0x90, 0x90, 0x90, 0x90)
if (-not (Test-Path -LiteralPath $studioBackup)) {
    $liveStudio = [IO.File]::ReadAllBytes($studioUiPath)
    foreach ($needle in $offlineCallFrom) {
        if ((Find-ByteSequence $liveStudio $needle) -lt 0) { throw "live NutStudioUI.dll is not the original 627 mailbox/music offline check; refusing to back up a patched binary" }
    }
    Copy-Item -LiteralPath $studioUiPath -Destination $studioBackup -Force
}
$studioBytes = [IO.File]::ReadAllBytes($studioBackup)
foreach ($needle in $offlineCallFrom) {
    $studioOffset = Find-ByteSequence $studioBytes $needle
    if ($studioOffset -lt 0) { throw "original NutStudioUI.dll missing 627 mailbox/music offline check" }
    for ($i = 0; $i -lt $offlineCallPatch.Length; $i++) {
        $studioBytes[$studioOffset + 8 + $i] = $offlineCallPatch[$i]
    }
}
[IO.File]::WriteAllBytes($studioUiPath, $studioBytes)
$verifyStudio = [IO.File]::ReadAllBytes($studioUiPath)
foreach ($needle in $offlineCallFrom) {
    if ((Find-ByteSequence $verifyStudio $needle) -ge 0) { throw "NutStudioUI.dll offline check patch did not persist" }
}

$containerPluginPath = Join-Path $GameRoot "$Version\plugins\Container\NutContainerPlugin.dll"
if (-not (Test-Path -LiteralPath $containerPluginPath)) { throw "NutContainerPlugin.dll not found: $containerPluginPath" }
$containerPluginBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("NutContainerPlugin-" + $Version + ".dll")
$containerPluginCallFrom = [byte[]](0x48, 0x8B, 0xDA, 0x48, 0x8B, 0xF9, 0xFF, 0x15, 0x61, 0xA4, 0x04, 0x00, 0x84, 0xC0, 0x0F, 0x85)
if (-not (Test-Path -LiteralPath $containerPluginBackup)) {
    $livePlugin = [IO.File]::ReadAllBytes($containerPluginPath)
    if ((Find-ByteSequence $livePlugin $containerPluginCallFrom) -lt 0) { throw "live NutContainerPlugin.dll is not the original 627 lite-bar offline check; refusing to back up a patched binary" }
    Copy-Item -LiteralPath $containerPluginPath -Destination $containerPluginBackup -Force
}
$pluginBytes = [IO.File]::ReadAllBytes($containerPluginBackup)
$pluginOffset = Find-ByteSequence $pluginBytes $containerPluginCallFrom
if ($pluginOffset -lt 0) { throw "original NutContainerPlugin.dll missing 627 lite-bar offline check" }
for ($i = 0; $i -lt $offlineCallPatch.Length; $i++) {
    $pluginBytes[$pluginOffset + 6 + $i] = $offlineCallPatch[$i]
}
[IO.File]::WriteAllBytes($containerPluginPath, $pluginBytes)
$verifyPlugin = [IO.File]::ReadAllBytes($containerPluginPath)
if ((Find-ByteSequence $verifyPlugin $containerPluginCallFrom) -ge 0) { throw "NutContainerPlugin.dll offline check patch did not persist" }

$userSettingsPath = Join-Path $env:APPDATA "miHoYo\Olivia-steam\store\usersettings.dat"
$widgetLockFrom = $latin1.GetBytes(([char]10).ToString() + "mailWidget" + [char]6 + [char]5 + "false" + [char]11 + "musicWidget" + [char]6 + [char]5 + "false")
$widgetLockTo = $latin1.GetBytes(([char]10).ToString() + "mailWidget" + [char]6 + [char]4 + "true" + [char]11 + "musicWidget" + [char]6 + [char]4 + "true")
if (Test-Path -LiteralPath $userSettingsPath) {
    $settingsBytes = [IO.File]::ReadAllBytes($userSettingsPath)
    $widgetOffset = Find-ByteSequence $settingsBytes $widgetLockFrom
    if ($widgetOffset -ge 0) {
        $settingsBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("usersettings-" + $Version + ".dat")
        if (-not (Test-Path -LiteralPath $settingsBackup)) {
            Copy-Item -LiteralPath $userSettingsPath -Destination $settingsBackup -Force
        }
        $patchedSettings = New-Object byte[] $settingsBytes.Length
        [Array]::Copy($settingsBytes, 0, $patchedSettings, 0, $widgetOffset)
        [Array]::Copy($widgetLockTo, 0, $patchedSettings, $widgetOffset, $widgetLockTo.Length)
        $restStart = $widgetOffset + $widgetLockFrom.Length
        [Array]::Copy($settingsBytes, $restStart, $patchedSettings, $widgetOffset + $widgetLockTo.Length, $settingsBytes.Length - $restStart)
        $newSize = [BitConverter]::ToInt32($patchedSettings, 0) - ($widgetLockFrom.Length - $widgetLockTo.Length)
        [Array]::Copy([BitConverter]::GetBytes($newSize), 0, $patchedSettings, 0, 4)
        [IO.File]::WriteAllBytes($userSettingsPath, $patchedSettings)
        if ((Find-ByteSequence ([IO.File]::ReadAllBytes($userSettingsPath)) $widgetLockTo) -lt 0) {
            throw "usersettings.dat mailWidget/musicWidget patch did not persist"
        }
        Write-Output "usersettings=$userSettingsPath"
    }
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
$studioHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $studioUiPath).Hash
$pluginHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $containerPluginPath).Hash
$webplayerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $webplayerLive).Hash
Write-Output "patched=$source"
Write-Output "sha256=$hash"
Write-Output "webplayer=$webplayerLive"
Write-Output "webplayerSha256=$webplayerHash"
Write-Output "studioUi=$studioUiPath"
Write-Output "studioUiSha256=$studioHash"
Write-Output "containerPlugin=$containerPluginPath"
Write-Output "containerPluginSha256=$pluginHash"
