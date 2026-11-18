# 한칸 · Hankan

Mac 화면에 사각형을 그리면 그 자리에 한국어 번역이 나타납니다. Apple Vision이 글자를 읽고, 같은 Mac에서 실행 중인 oMLX가 문단을 번역합니다.

## 빌드와 실행

Apple Silicon Mac과 macOS 14 이상, Swift 컴파일러가 포함된 Xcode Command Line Tools가 필요합니다. 번역하려면 [oMLX](https://github.com/jundot/omlx)를 실행하고 TranslateGemma 4B 4bit 모델을 준비하세요. 앱은 로컬 oMLX 설정에서 포트와 인증 정보를 읽습니다.

```sh
./build.sh
open "build/한칸.app"
```

**영역 번역**을 누른 뒤 읽고 싶은 부분을 드래그하세요. 처음 실행할 때 macOS가 화면 기록 권한을 요청하면 한칸을 허용하고 앱을 다시 여세요.

정지 화면의 수평 문단에서 원문 언어를 자동 감지합니다. Space로 원문과 번역을 전환하고, 문단을 클릭해 전체 번역을 보거나 Esc로 닫을 수 있습니다. 저장한 스크린샷은 **이미지 열기**로 읽을 수 있습니다.

[MIT 라이선스](LICENSE)
