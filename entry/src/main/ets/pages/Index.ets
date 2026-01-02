import { socket } from '@kit.NetworkKit';
import { audio } from '@kit.AudioKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { vibrator } from '@kit.SensorServiceKit';
import { promptAction, PromptAction } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  promptAction: PromptAction = this.getUIContext().getPromptAction();
  private audioQueue: ArrayBuffer[] = [];
  private isBufferReady: boolean = false; // Prevents playing until we have enough data
  private readonly BUFFER_THRESHOLD = 3;  // Wait for 3 packets before starting  // --- UI States ---
  @State isPageConnected: boolean = false;
  @State isSearching: boolean = false;
  @State myIp: string = '-';
  @State remoteIp: string = '';
  @State statusMsg: string = '';
  @State activePort: number = 4567;
  @State callDuration: string = '00:00';
  // --- Network & Audio Instances ---
  private scroller: Scroller = new Scroller();
  private tcpServer: socket.TCPSocketServer | undefined = undefined;
  private tcpClient: socket.TCPSocket | undefined = undefined;
  private activeSocket: socket.TCPSocket | socket.TCPSocketConnection | undefined = undefined;
  private audioCapturer?: audio.AudioCapturer;
  private audioRenderer?: audio.AudioRenderer;
  // --- Timers ---
  private durationTimer: number = -1;
  private knockTimer: number = -1;
  private secondsElapsed: number = 0;

  async aboutToAppear() {
    // Initial status from string.json
    this.statusMsg = this.context.resourceManager.getStringSync($r('app.string.status_ready').id);
    await this.requestPermissions();
    await this.refreshIp();
    this.initAudio();
  }

  async refreshIp() {
    try {
      const ipAddr = wifiManager.getIpInfo().ipAddress;
      if (ipAddr !== 0) {
        // Correcting Byte Order: Little-Endian to Network String
        const b1 = (ipAddr & 0xFF);
        const b2 = ((ipAddr >> 8) & 0xFF);
        const b3 = ((ipAddr >> 16) & 0xFF);
        const b4 = ((ipAddr >> 24) & 0xFF);
        this.myIp = `${b1}.${b2}.${b3}.${b4}`;
      }
    } catch (e) {
      console.error('P2P_LOG: IP Refresh Error');
    }
  }

  startHosting(targetPort: number = 4567) {
    this.isSearching = true;
    // Uses %d placeholder from string.json
    this.statusMsg = this.context.resourceManager.getStringSync($r('app.string.status_hosting').id, targetPort);

    if (this.tcpServer) {
      try {
        this.tcpServer.close()
      } catch (e) {
      }
    }

    this.tcpServer = socket.constructTCPSocketServerInstance();
    this.tcpServer.listen({ address: this.context.resourceManager.getStringSync($r('app.string.ip_address').id), port: targetPort }, (err) => {
      if (err) {
        if (err.code === 2303199) {
          this.startHosting(targetPort + 1);
        } else {
          this.isSearching = false;
          this.statusMsg =
            this.context.resourceManager.getStringSync($r('app.string.msg_net_error').id, err.code.toString());
        }
        return;
      }

      this.activePort = targetPort;
      this.statusMsg = this.context.resourceManager.getStringSync($r('app.string.status_waiting').id);

      this.tcpServer?.on('connect', (client) => {
        this.activeSocket = client;
        client.on('message', (res) => {
          if (res.message.byteLength < 500) {
            client.send({ data: new Uint8Array([0xAA, 0xBB]).buffer });
            this.setupSocketListeners();
            this.startCall();
          }
        });
      });
    });
  }

  startConnecting() {
    if (this.remoteIp.length < 7) {
      promptAction.openToast({ message: $r('app.string.msg_invalid_ip') });
      return;
    }
    this.isSearching = true;
    this.statusMsg = this.context.resourceManager.getStringSync($r('app.string.status_connecting').id);

    if (this.tcpClient) {
      try {
        this.tcpClient.close();
      } catch (e) {
      }
    }

    this.tcpClient = socket.constructTCPSocketInstance();
    this.tcpClient.bind({ address: this.context.resourceManager.getStringSync($r('app.string.ip_address').id), port: 0 }, (err) => {
      this.tcpClient?.connect({
        address: { address: this.remoteIp, port: this.activePort },
        timeout: 8000
      }, (connErr) => {
        if (connErr) {
          this.isSearching = false;
          this.statusMsg = this.context.resourceManager.getStringSync($r('app.string.status_ready').id);
          return;
        }

        this.activeSocket = this.tcpClient;
        this.activeSocket?.on('message', (res) => {
          if (res.message.byteLength < 500) {
            clearInterval(this.knockTimer);
            this.setupSocketListeners();
            this.startCall();
          }
        });

        this.knockTimer = setInterval(() => {
          if (!this.isPageConnected && this.activeSocket) {
            const knock = new Uint8Array(200);
            knock[0] = 0xCC;
            this.activeSocket.send({ data: knock.buffer });
          }
        }, 1200);
      });
    });
  }

  setupSocketListeners() {
    if (!this.activeSocket){return;}
    this.activeSocket.off('message');
    this.activeSocket.on('message', (res) => {
      if (this.isPageConnected && res.message.byteLength > 500) {
        this.audioQueue.push(res.message);

        // Once we hit the threshold, allow the renderer to start pulling
        if (this.audioQueue.length >= this.BUFFER_THRESHOLD) {
          this.isBufferReady = true;
        }

        if (this.audioQueue.length > 10) {
          this.audioQueue.shift();
        }
      }
    });
    this.activeSocket.on('close', () => this.stopCall());
  }

  async startCall() {
    this.isPageConnected = true;
    this.isSearching = false;
    try {
      await this.audioCapturer?.start(); // Triggers readData callbacks
      await this.audioRenderer?.start(); // Triggers writeData callbacks
      this.startTimers();
      vibrator.startVibration({ type: 'time', duration: 200 }, { id: 0, usage: 'alarm' });
    } catch (e) { this.stopCall(); }
  }

  stopCall() {
    this.isPageConnected = false;
    this.isSearching = false;
    clearInterval(this.durationTimer);
    clearInterval(this.knockTimer);
    this.audioCapturer?.stop();
    this.audioRenderer?.stop();
    this.audioQueue = []; // HIGHLIGHT: Clear the audio buffer
    this.isBufferReady = false;
    try {
      this.activeSocket?.close().catch(() => {
      });
    } catch (e) {
    }
    this.statusMsg = this.context.resourceManager.getStringSync($r('app.string.status_ready').id);
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        if (!this.isPageConnected) {
          Text($r('app.string.app_title'))
            .fontSize(25).fontWeight(FontWeight.Bold).margin({ top: 40, bottom: 10 }).fontColor('#007DFF')

          if (this.isSearching) {
            LoadingProgress().width(50).height(50).margin(10)
            Text(this.statusMsg).fontColor(Color.White).margin(5)
            Button($r('app.string.btn_cancel'))
              .width('80%').margin(20).backgroundColor('#333')
              .onClick(() => this.stopCall())
          } else {
            // Uses %s placeholder for IP
            Text(this.context.resourceManager.getStringSync($r('app.string.label_my_ip').id, this.myIp))
              .margin(10).fontColor('#999').fontSize(14)

            Button($r('app.string.btn_become_host'))
              .width('85%').height(55).margin(10)
              .onClick(() => this.startHosting())

            Divider().color('#222').margin(15).width('80%')

            TextInput({ placeholder: $r('app.string.placeholder_ip'), text: this.remoteIp })
              .width('85%')
              .height(50)
              .margin(5)
              .backgroundColor('#111')
              .fontColor(Color.White)
              .onChange(v => this.remoteIp = v)

            TextInput({ placeholder: $r('app.string.placeholder_port'), text: this.activePort.toString() })
              .width('85%')
              .height(50)
              .margin(5)
              .backgroundColor('#111')
              .fontColor(Color.White)
              .onChange(v => this.activePort = parseInt(v))

            Button($r('app.string.btn_join_call'))
              .width('85%')
              .height(55)
              .margin(10)
              .backgroundColor('#222')
              .onClick(() => this.startConnecting())
          }
        } else {
          Text($r('app.string.status_connected'))
            .fontSize(18).fontColor('#00FF00').margin({ top: 50 })

          Text(this.callDuration)
            .fontSize(55).fontWeight(FontWeight.Bold).margin({ top: 10 }).fontColor(Color.White)

          Button($r('app.string.btn_end_call'))
            .width('85%')
            .height(60)
            .margin({ top: 80 })
            .backgroundColor('#FF454F')
            .onClick(() => this.stopCall())
        }
      }.width('100%')
    }.width('100%').height('100%').backgroundColor(Color.Black).scrollBar(BarState.Off)
  }

  async requestPermissions() {
    const atManager = abilityAccessCtrl.createAtManager();
    await atManager.requestPermissionsFromUser(this.context as common.UIAbilityContext,
      ['ohos.permission.MICROPHONE', 'ohos.permission.INTERNET', 'ohos.permission.GET_WIFI_INFO']);
  }

  // --- OPTIMIZED AUDIO INIT ---
  async initAudio() {
    try {
      let info: audio.AudioStreamInfo = {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      };

      this.audioCapturer = await audio.createAudioCapturer({
        streamInfo: info,
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, capturerFlags: 0 }
      });

      this.audioRenderer = await audio.createAudioRenderer({
        streamInfo: info,
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION, rendererFlags: 0 }
      });

      this.audioCapturer.on('readData', (buffer: ArrayBuffer) => {
        if (this.isPageConnected && this.activeSocket) {
          this.activeSocket.send({ data: buffer });
        }
      });

      this.audioRenderer.on('writeData', (buffer: ArrayBuffer) => {
        // Only play if we have data AND we've finished pre-buffering
        if (this.isBufferReady && this.audioQueue.length > 0) {
          let data = this.audioQueue.shift();
          if (data) {
            let dst = new Uint8Array(buffer);
            let src = new Uint8Array(data);
            // Ensure we don't overflow the hardware buffer
            dst.set(src.slice(0, buffer.byteLength));
          }
        } else {
          // If we ran out of data, stop playing until we buffer again
          this.isBufferReady = false;
          // Fill hardware buffer with silence to prevent "static" noise
          new Uint8Array(buffer).fill(0);
        }
      });

    } catch (e) {
      console.error('P2P_LOG: Audio Setup Failed');
    }
  }

  startTimers() {
    this.secondsElapsed = 0;
    this.durationTimer = setInterval(() => {
      this.secondsElapsed++;
      const mins = Math.floor(this.secondsElapsed / 60).toString().padStart(2, '0');
      const secs = (this.secondsElapsed % 60).toString().padStart(2, '0');
      this.callDuration = `${mins}:${secs}`;
    }, 1000);
  }
}