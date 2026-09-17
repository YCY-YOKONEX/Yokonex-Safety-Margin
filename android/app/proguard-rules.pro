# ML Kit 通过清单中的类名反射创建组件，必须保留公开无参构造器。
-keepclassmembers class * implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}

# Room 根据数据库类名反射创建生成的 _Impl 实现，必须保留类名和无参构造器。
-keepnames class * extends androidx.room.RoomDatabase
-keepclassmembers class * extends androidx.room.RoomDatabase {
    <init>();
}
-keep class androidx.work.impl.WorkDatabase_Impl {
    <init>();
}
