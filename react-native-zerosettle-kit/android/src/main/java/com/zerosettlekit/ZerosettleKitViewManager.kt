package com.zerosettlekit

import android.graphics.Color
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.ZerosettleKitViewManagerInterface
import com.facebook.react.viewmanagers.ZerosettleKitViewManagerDelegate

@ReactModule(name = ZerosettleKitViewManager.NAME)
class ZerosettleKitViewManager : SimpleViewManager<ZerosettleKitView>(),
  ZerosettleKitViewManagerInterface<ZerosettleKitView> {
  private val mDelegate: ViewManagerDelegate<ZerosettleKitView>

  init {
    mDelegate = ZerosettleKitViewManagerDelegate(this)
  }

  override fun getDelegate(): ViewManagerDelegate<ZerosettleKitView>? {
    return mDelegate
  }

  override fun getName(): String {
    return NAME
  }

  public override fun createViewInstance(context: ThemedReactContext): ZerosettleKitView {
    return ZerosettleKitView(context)
  }

  @ReactProp(name = "color")
  override fun setColor(view: ZerosettleKitView?, color: Int?) {
    view?.setBackgroundColor(color ?: Color.TRANSPARENT)
  }

  companion object {
    const val NAME = "ZerosettleKitView"
  }
}
