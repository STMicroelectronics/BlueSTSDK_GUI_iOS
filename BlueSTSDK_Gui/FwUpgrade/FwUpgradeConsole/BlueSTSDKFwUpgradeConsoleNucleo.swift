 /*
  * Copyright (c) 2018  STMicroelectronics – All rights reserved
  * The STMicroelectronics corporate logo is a trademark of STMicroelectronics
  *
  * Redistribution and use in source and binary forms, with or without modification,
  * are permitted provided that the following conditions are met:
  *
  * - Redistributions of source code must retain the above copyright notice, this list of conditions
  *   and the following disclaimer.
  *
  * - Redistributions in binary form must reproduce the above copyright notice, this list of
  *   conditions and the following disclaimer in the documentation and/or other materials provided
  *   with the distribution.
  *
  * - Neither the name nor trademarks of STMicroelectronics International N.V. nor any other
  *   STMicroelectronics company nor the names of its contributors may be used to endorse or
  *   promote products derived from this software without specific prior written permission.
  *
  * - All of the icons, pictures, logos and other images that are provided with the source code
  *   in a directory whose title begins with st_images may only be used for internal purposes and
  *   shall not be redistributed to any third party or modified in any way.
  *
  * - Any redistributions in binary form shall not include the capability to display any of the
  *   icons, pictures, logos and other images that are provided with the source code in a directory
  *   whose title begins with st_images.
  *
  * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
  * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
  * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER
  * OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
  * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
  * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
  * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
  * OF SUCH DAMAGE.
  */

import Foundation
import BlueSTSDK

 
/// Upload a firmware in the Nucleo Boards, using the debug console.
public class BlueSTSDKFwUpgradeConsoleNucleo:BlueSTSDKFwUpgradeConsole{
    
    private let mConsole:BlueSTSDKDebug;
    private var mConsoleDelegate:LoadFwDelegate?;
    private var mFwUploadDelegate:BlueSTSDKFwUpgradeConsoleCallback?;
    
    init(console:BlueSTSDKDebug){
        mConsole = console;
    }
    
    public func loadFwFile(type: BlueSTSDKFwUpgradeType,
                           file: URL,
                           delegate: BlueSTSDKFwUpgradeConsoleCallback,
                           address:UInt32?) -> Bool {
        guard type == .applicationFirmware else{
            delegate.onLoadError(file: file, error: .unsupportedOperation)
            return false
        }
        guard mConsoleDelegate == nil else {
            //we are already doing an upload
            return false;
        }
        
        mFwUploadDelegate = delegate;
        
        do{
            let fileHandler = try FileHandle(forReadingFrom: file)
            let data = fileHandler.readDataToEndOfFile()
            mConsoleDelegate = LoadFwDelegate(console: mConsole, delegate: delegate,fwData: data,fileUrl: file)
            fileHandler.closeFile()
            mConsoleDelegate?.startLoading()
        }catch{
            mConsoleDelegate=nil;
            delegate.onLoadError(file: file, error: .invalidFwFile)
            return false;
        }
        
        return true;
    }
}
 
 
 /// Implement the Fw upgrade logic on top of the DebugCosole
 class LoadFwDelegate : BlueSTSDKDebugOutputDelegate{
    private static let ACK_REPS = "\u{01}"
    private static let TIMEOUT_S = 1.0
    private static let MAX_MSG_SIZE = Int(16)
    private static let N_BLOCK_PACKAGE = 10
    private static let MSG_DELAY_NS = NSEC_PER_SEC/90
    
    private let mMessageSerializer:DispatchQueue
    private var mDelegate:BlueSTSDKFwUpgradeConsoleCallback?
    private let mConsole: BlueSTSDKDebug
    private let mFileUrl:URL
    private let mFileData:Data
    private var mCurrentTimeOut:DispatchWorkItem?
    private var mCrc:UInt32
    
    private var mNodeReadyToReceiveFile=false;
    private var mNPackageReceived:Int=0;
    private var mByteSend:Int=0;
    
    private func setUpTimer(){
        mCurrentTimeOut?.cancel()
        mCurrentTimeOut = DispatchWorkItem{
            self.onLoadFailWithError(.trasmissionError)
        }
        mMessageSerializer.asyncAfter(deadline: .now()+LoadFwDelegate.TIMEOUT_S, execute: mCurrentTimeOut!)
    }
    
    private func onLoadFailWithError(_ error:BlueSTSDKFwUpgradeError){
        mDelegate?.onLoadError(file: mFileUrl, error: error)
        mConsole.remove(self)
        mDelegate=nil
    }
    
    private func onLoadComplete(){
        mConsole.remove(self)
        mDelegate?.onLoadProgres(file: mFileUrl, remainingBytes: 0)
        mDelegate?.onLoadComplite(file: mFileUrl)
        mDelegate=nil
    }
    
    private static func getSTM32Crc(_ data:Data) -> UInt32{
        let length = data.count - data.count % 4
        let tempData = data[0...length]
        let crcEngine = BlueSTSDKSTM32CRC()
        crcEngine.upgrade(tempData)
        return crcEngine.crcValue
    }
    
    private static func buildLoadCommand(fileLength:Int, crc:UInt32)->Data{
        
        var command = Data()
        let commandData = "upgradeFw".data(using: .isoLatin1)
        command.append(commandData!)
        
        //copy the varialbe otherwise Im not able to append it..
        var myCrc = crc;
        var myFileLength = UInt32(fileLength)
        command.append(UnsafeBufferPointer(start: &myFileLength, count: 1))
        command.append(UnsafeBufferPointer(start: &myCrc, count: 1))
        return command
    }
    
    init(console: BlueSTSDKDebug, delegate:BlueSTSDKFwUpgradeConsoleCallback,fwData:Data,fileUrl:URL ) {
        mMessageSerializer = DispatchQueue(label: "LoadFwDelegate")
        mDelegate = delegate
        mFileUrl=fileUrl
        mFileData = fwData
        mConsole = console
        mCrc = BlueSTSDKSTM32CRC.getCrc(mFileData);
    }
    
    private func checkCrc(response:String)->Bool{
        let data = response.data(using: .isoLatin1)
        let ackCrc = data?.withUnsafeBytes{ (ptr:UnsafePointer<UInt32>) in
            return ptr.pointee
        }
        return ackCrc == mCrc
    }
    
    public func startLoading(){
        mNodeReadyToReceiveFile=false;
        mByteSend=0
        mNPackageReceived=0
        mConsole.add(self)
        let commandData = LoadFwDelegate.buildLoadCommand(fileLength: mFileData.count, crc: mCrc)
        mConsole.writeMessageData(commandData)
    }
    
    func debug(_ debug: BlueSTSDKDebug, didStdOutReceived msg: String) {
        if (!mNodeReadyToReceiveFile) {
            if (checkCrc(response: msg)) {
                mNodeReadyToReceiveFile = true;
                mNPackageReceived = 0;
                sendPackageBlock()
            } else{
                onLoadFailWithError(.trasmissionError)
            }
        } else { //transfer complete
            mCurrentTimeOut?.cancel()
            print(msg.debugDescription)
            print(LoadFwDelegate.ACK_REPS.debugDescription)
            print(msg.count)
            print(LoadFwDelegate.ACK_REPS.count)
            print(msg.compare(LoadFwDelegate.ACK_REPS))
            if(msg == LoadFwDelegate.ACK_REPS){
                onLoadComplete()
            }else{
                onLoadFailWithError(.corruptedFile)
            }
        }//if
    }
    

    
    private func sendFwPackage()->Bool{
        let packageSize = min(mFileData.count-mByteSend, LoadFwDelegate.MAX_MSG_SIZE)
        guard packageSize != 0 else {
            return false; // nothing to send
        }
        let dataToSend = mFileData[mByteSend..<mByteSend+packageSize]
        
        mByteSend = mByteSend + packageSize
        mConsole.writeMessageDataFast(dataToSend)
        return true
    }
    
    /**
     * send a block of message, the function will stop at the first error
     */
    private func sendPackageBlock(){
        let when = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds+LoadFwDelegate.MSG_DELAY_NS)
        mMessageSerializer.asyncAfter(deadline: when){
            if(self.sendFwPackage()){
                self.sendPackageBlock()
            }
        }
    }
    
    func debug(_ debug: BlueSTSDKDebug, didStdErrReceived msg: String) {
        
    }
    
    private func notifyNodeReceivedFwMessage(){
        mNPackageReceived=mNPackageReceived+1
        if(mNPackageReceived % LoadFwDelegate.N_BLOCK_PACKAGE == 0){
            mDelegate?.onLoadProgres(file: mFileUrl, remainingBytes: UInt(mFileData.count - mByteSend))
        }
    }
    
    func debug(_ debug: BlueSTSDKDebug, didStdInSend msg: String, error: Error?) {
        guard error==nil else {
            onLoadFailWithError(.trasmissionError)
            return
        }
        if(mNodeReadyToReceiveFile){
            mCurrentTimeOut?.cancel()
            notifyNodeReceivedFwMessage()
            setUpTimer()
        }else{
            print(msg)
        }
    }
    
 }

