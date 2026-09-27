#!/usr/bin/env bash
# Сборка серии 1 «Дверь без ошибки» в песочнице Higgsfield (ffmpeg + libass).
# Вход: URL кадров и реплик (env S1..S7, V2..V6). Выход: ep01_master.mp4 (~44 с) и ep01_15s.mp4.
set -euo pipefail
cd /home/user && mkdir -p ep01 && cd ep01

dl() { [ -s "$2" ] || curl -sf -o "$2" "$1"; }
dl "$S1" s1.mp4; dl "$S2" s2.mp4; dl "$S3" s3.mp4; dl "$S4" s4.mp4
dl "$S5" s5.mp4; dl "$S6" s6.mp4; dl "$S7" s7.mp4
dl "$V1" v1.wav; dl "$V2" v2.wav; dl "$V3" v3.wav; dl "$V4" v4.wav
dl "$V5" v5.wav; dl "$V6" v6.wav; dl "$V7" v7.wav

N="scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30,format=yuv420p,setsar=1"

# seg <idx> <video> <length> <vo.wav|-> <vo_delay_ms> <sfx_gain>
# Говорящие кадры (1, 7): голос — исходная реплика героя с t=0, родной звук модели не используем.
seg() {
  local i=$1 v=$2 len=$3 vo=$4 d=$5 g=$6
  if [ "$vo" = "-" ]; then
    ffmpeg -v error -y -i "$v" -f lavfi -t "$len" -i anullsrc=r=48000:cl=stereo \
      -filter_complex "[0:v]$N,tpad=stop_mode=clone:stop_duration=3,trim=0:$len,setpts=PTS-STARTPTS[v];[1:a]anull[a]" \
      -map "[v]" -map "[a]" -t "$len" -c:v libx264 -crf 18 -preset fast -c:a aac -ar 48000 "seg$i.mp4"
  else
    local sfx="anullsrc=r=48000:cl=stereo"
    if ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$v" | grep -q .; then
      sfx="[0:a]aresample=48000,volume=$g,apad"
    else sfx="anullsrc=r=48000:cl=stereo"; fi
    ffmpeg -v error -y -i "$v" -i "$vo" \
      -filter_complex "[0:v]$N,tpad=stop_mode=clone:stop_duration=3,trim=0:$len,setpts=PTS-STARTPTS[v];$sfx[s];[1:a]aresample=48000,pan=stereo|c0=c0|c1=c0,adelay=$d|$d,apad[vo];[s][vo]amix=inputs=2:normalize=0,atrim=0:$len[a]" \
      -map "[v]" -map "[a]" -t "$len" -c:v libx264 -crf 18 -preset fast -c:a aac -ar 48000 "seg$i.mp4"
  fi
}

seg 1 s1.mp4 4.0 v1.wav 0 0
seg 2 s2.mp4 6.0 v2.wav 100 0.35
seg 3 s3.mp4 7.0 v3.wav 500 0.45
seg 4 s4.mp4 8.5 v4.wav 200 0.30
seg 5 s5.mp4 6.4 v5.wav 200 0.40
seg 6 s6.mp4 6.0 v6.wav 500 0.30
seg 7 s7.mp4 6.0 v7.wav 0 0

printf "file 'seg%s.mp4'\n" 1 2 3 4 5 6 7 > list.txt
ffmpeg -v error -y -f concat -safe 0 -i list.txt -c copy raw.mp4

python3 - <<'PY'
def t(s):
    h=int(s//3600); m=int(s%3600//60); x=s%60
    return f"{h}:{m:02d}:{x:05.2f}"
# (старт реплики на таймлайне, длительность, фразы)
vo=[(0.0,3.88,["Эту дверь воры даже не пытаются открыть.","Сейчас покажу почему."]),
    (4.1,5.8,["Обычная дверь: тонкий лист, один замок,","петли снаружи. Такая не остановит."]),
    (10.5,4.0,["Признак первый — запирание","по всему периметру, а не в одной точке."]),
    (17.2,8.18,["Второй — смотрите на срез:","толщина металла и наполнение,","а не картинка в каталоге."]),
    (25.7,6.08,["Третий — скрытые петли","и противосъёмные штыри.","Снаружи зацепиться не за что."]),
    (32.4,5.08,["В шоуруме на Сайханова всё это","можно потрогать руками и сравнить."]),
    (37.9,5.08,["Дверь без ошибки — Империя дверей.","Напишите «+» — подберём вашу."])]
labels=[(0.15,3.85,"ДВЕРЬ БЕЗ ОШИБКИ · №1"),
        (4.2,9.8,"Тонкий лист · 1 замок · петли снаружи"),
        (10.3,16.8,"ПРИЗНАК 1 · ригели по периметру"),
        (17.2,25.3,"ПРИЗНАК 2 · срез: металл + наполнение"),
        (25.7,31.7,"ПРИЗНАК 3 · скрытые петли + противосъёмы"),
        (32.1,37.7,"Грозный · Сайханова, 172"),
        (38.0,43.9,"Напишите «+» в комментариях")]
head="""[Script Info]
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Sub,Montserrat ExtraBold,54,&H00FFFFFF,&H00FFFFFF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,4,2,2,70,70,360,1
Style: Label,Montserrat ExtraBold,50,&H005AA1C8,&H005AA1C8,&H00000000,&H96000000,0,0,0,0,100,100,1,0,3,14,0,8,60,60,190,1
Style: Brand,Montserrat ExtraBold,78,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,4,0,1,5,3,5,60,60,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
ev=[]
for st,du,parts in vo:
    tot=sum(len(p) for p in parts); c=st
    for p in parts:
        d=du*len(p)/tot
        ev.append(f"Dialogue: 0,{t(c)},{t(c+d)},Sub,,0,0,0,,{p}"); c+=d
for a,b,txt in labels:
    ev.append(f"Dialogue: 1,{t(a)},{t(b)},Label,,0,0,0,,{{\\fad(150,150)}}{txt}")
ev.append("Dialogue: 2,0:00:42.40,0:00:43.90,Brand,,0,0,0,,{\\fad(200,0)}ИМПЕРИЯ ДВЕРЕЙ")
open("ep01.ass","w").write(head+"\n".join(ev)+"\n")
PY

ffmpeg -v error -y -i raw.mp4 -vf "ass=ep01.ass" -c:v libx264 -crf 18 -preset medium -c:a aac -b:a 192k -movflags +faststart ep01_master.mp4

# Нарезка 15 с: хук (0–4) + признак 1 (10–14.6) + финал (37.9–43.9)
ffmpeg -v error -y -i ep01_master.mp4 -filter_complex \
 "[0:v]trim=0:4,setpts=PTS-STARTPTS[v1];[0:a]atrim=0:4,asetpts=PTS-STARTPTS[a1];\
  [0:v]trim=10:14.6,setpts=PTS-STARTPTS[v2];[0:a]atrim=10:14.6,asetpts=PTS-STARTPTS[a2];\
  [0:v]trim=37.9:43.9,setpts=PTS-STARTPTS[v3];[0:a]atrim=37.9:43.9,asetpts=PTS-STARTPTS[a3];\
  [v1][a1][v2][a2][v3][a3]concat=n=3:v=1:a=1[v][a]" \
 -map "[v]" -map "[a]" -c:v libx264 -crf 18 -preset medium -c:a aac -b:a 192k -movflags +faststart ep01_15s.mp4

for f in ep01_master.mp4 ep01_15s.mp4; do
  printf "%s " "$f"; ffprobe -v error -show_entries format=duration:stream=codec_type,width,height -of csv=p=0 "$f" | tr '\n' ' '; echo
done
