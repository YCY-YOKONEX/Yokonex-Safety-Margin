allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// flutter_reactive_ble 的原生模块自带 compileSdk 33，
// 和新版 AndroidX 依赖（需要 34+）冲突，这里统一对齐到 app 使用的版本。
// evaluationDependsOn(":app") 会导致部分子项目在到达这里时已完成求值，
// 因此需要判断是否已求值，避免对已求值项目调用 afterEvaluate 报错。
subprojects {
    fun alignCompileSdk() {
        if (extensions.findByName("android") != null) {
            extensions.getByName("android").withGroovyBuilder {
                setProperty("compileSdkVersion", 36)
            }
        }
    }
    if (state.executed) {
        alignCompileSdk()
    } else {
        afterEvaluate { alignCompileSdk() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
