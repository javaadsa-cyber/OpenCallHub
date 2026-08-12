# ---------- 构建阶段 ----------
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /build

ARG MODULE
ARG JAR_FILE

# 先拷贝全部 pom，利用 Docker 层缓存依赖解析
COPY pom.xml ./
COPY och-security/pom.xml och-security/
COPY och-system/pom.xml och-system/
COPY och-api/pom.xml och-api/
COPY och-esl/pom.xml och-esl/
COPY och-file/pom.xml och-file/
COPY och-websocket/pom.xml och-websocket/
COPY och-ivr/pom.xml och-ivr/
COPY och-mrcp/pom.xml och-mrcp/
COPY och-file-client/pom.xml och-file-client/
COPY och-ai/pom.xml och-ai/
COPY och-call-task/pom.xml och-call-task/

RUN mvn -q -B -pl ${MODULE} -am dependency:resolve -DskipTests || true

# 再拷贝源码并打包（测试需要真实云服务密钥，必须跳过）
COPY . .
RUN mvn -B -pl ${MODULE} -am package -DskipTests \
    && cp ${MODULE}/target/${JAR_FILE} /app.jar

# ---------- 运行阶段 ----------
FROM eclipse-temurin:17-jre
LABEL org.opencontainers.image.source="OpenCallHub"

ARG MAIN_CLASS=""
ENV TZ=Asia/Shanghai \
    JAVA_OPTS="" \
    MAIN_CLASS=${MAIN_CLASS}

WORKDIR /app
COPY --from=build /app.jar /app/app.jar

# 录音/上传目录（对应 system.setting.fsProfile / baseProfile）
# /app/config 用于 och-mrcp 的 HOCON 配置覆盖（classpath 前置）
RUN mkdir -p /record /temp /app/config

# MAIN_CLASS 为空 => Spring Boot 可执行 jar 直接 -jar 启动；
# MAIN_CLASS 非空（och-mrcp）=> 以 classpath 方式启动，/app/config 前置以支持 conf 覆盖
ENTRYPOINT ["sh", "-c", "if [ -n \"$MAIN_CLASS\" ]; then exec java $JAVA_OPTS -cp /app/config:/app/app.jar $MAIN_CLASS; else exec java $JAVA_OPTS -jar /app/app.jar; fi"]
