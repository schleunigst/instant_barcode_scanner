# ML Kit component discovery instantiates registrars via reflection; R8 full
# mode strips their no-arg constructors, which breaks
# BarcodeScanning.getClient() with an MlKitContext init failure.
-keep class * implements com.google.mlkit.common.component.ComponentRegistrar { *; }
-keep class com.google.mlkit.common.internal.CommonComponentRegistrar { *; }
-keep class com.google.mlkit.vision.barcode.internal.BarcodeRegistrar { *; }
