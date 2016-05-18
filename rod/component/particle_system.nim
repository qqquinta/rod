import times
import math
import json
import tables

import rod.quaternion

import rod.node
import rod.component
import rod.rod_types
import rod.property_visitor
import rod.viewport
import rod.component.particle_helpers
import rod.component.camera
import rod.material.shader
import rod.tools.serializer_helpers

import nimx.matrixes
import nimx.animation
import nimx.context
import nimx.types
import nimx.portable_gl
import nimx.view
import nimx.image

const ParticleVertexShader = """
attribute vec3 aPosition;
#ifdef ROTATION_3D
    attribute vec3 aRotation;
#else
    attribute float aRotation;
#endif
attribute vec3 aScale;
attribute float aAlpha;
attribute float aColor;
attribute float aID;

uniform mat4 modelViewProjectionMatrix;
uniform mat4 projMatrix;
uniform mat4 viewMatrix;
uniform mat4 worldMatrix;

varying float vAlpha;
varying float vColor;
varying vec2 texCoords;

#ifdef ROTATION_3D
    mat4 getRotationMatrix(vec3 rot)
    {
        float angle = radians(rot.x);
        mat4 rMatrixX = mat4(
        1.0, 0.0,        0.0,         0.0,
        0.0, cos(angle), -sin(angle), 0.0,
        0.0, sin(angle), cos(angle) , 0.0,
        0.0, 0.0,        0.0,         1.0 );

        angle = radians(rot.y);
        mat4 rMatrixY = mat4(
        cos(angle),  0.0, sin(angle), 0.0,
        0.0, 1.0,    0.0,             0.0,
        -sin(angle), 0.0, cos(angle), 0.0,
        0.0,         0.0, 0.0,        1.0 );

        angle = radians(rot.z);
        mat4 rMatrixZ = mat4(
        cos(angle), -sin(angle), 0.0, 0.0,
        sin(angle), cos(angle),  0.0, 0.0,
        0.0,        0.0,         1.0, 0.0,
        0.0,        0.0,         0.0, 1.0 );

        return rMatrixX * rMatrixY * rMatrixZ;
    }
#else
    mat4 getRotationMatrix(float rot)
    {
        float angle = radians(rot);
        mat4 rMatrixZ = mat4(
        cos(angle), -sin(angle), 0.0, 0.0,
        sin(angle), cos(angle),  0.0, 0.0,
        0.0,        0.0,         1.0, 0.0,
        0.0,        0.0,         0.0, 1.0 );

        return rMatrixZ;
    }
#endif

void main()
{
    vAlpha = aAlpha;
    vColor = aColor;

    vec3 vertexOffset;
    if (aID == 0.0) { vertexOffset = vec3(-0.5,  0.5, 0); }
    if (aID == 1.0) { vertexOffset = vec3( 0.5,  0.5, 0); }
    if (aID == 2.0) { vertexOffset = vec3( 0.5,  -0.5, 0); }
    if (aID == 3.0) { vertexOffset = vec3(-0.5,  -0.5, 0); }

    texCoords = vec2(vertexOffset.xy) + vec2(0.5, 0.5);
    vertexOffset = vertexOffset * aScale;

    mat4 rMatrix = getRotationMatrix(aRotation);
    vec4 rotatedVertexOffset = rMatrix * vec4(vertexOffset, 1.0);

    mat4 modelView = viewMatrix;// * worldMatrix;
    vec4 transformedPos = viewMatrix * vec4(aPosition, 1.0);

#ifndef ROTATION_3D
    modelView[0][0] = 1.0;    modelView[1][0] = 0.0;    modelView[2][0] = 0.0;
    modelView[0][1] = 0.0;    modelView[1][1] = 1.0;    modelView[2][1] = 0.0;
    modelView[0][2] = 0.0;    modelView[1][2] = 0.0;    modelView[2][2] = 1.0;
#endif
    // transformation already is in transformedPos
    modelView[3][0] = 0.0;    modelView[3][1] = 0.0;    modelView[3][2] = 0.0;

    vec4 P = modelView * vec4(rotatedVertexOffset.xyz + transformedPos.xyz, 1.0);
    gl_Position = projMatrix * P;
}
"""
const ParticleFragmentShader = """
#ifdef GL_ES
#extension GL_OES_standard_derivatives : enable
precision mediump float;
#endif

#ifdef TEXTURED
    uniform sampler2D texUnit;
    uniform vec4 uTexUnitCoords;
#endif

varying float vAlpha;
varying float vColor;
varying vec2 texCoords;

vec3 encodeRgbFromFloat( float f )
{
    vec3 color;
    color.b = floor(f / (256.0 * 256.0));
    color.g = floor((f - color.b * 256.0 * 256.0) / 256.0);
    color.r = floor(f - color.b * 256.0 * 256.0 - color.g * 256.0);
    return color / 256.0;
}

void main()
{
#ifdef TEXTURED
    vec4 texture = texture2D(texUnit, uTexUnitCoords.xy + (uTexUnitCoords.zw - uTexUnitCoords.xy) * texCoords);
    gl_FragColor = texture * vec4(encodeRgbFromFloat(vColor), vAlpha);
#else
    gl_FragColor = vec4(encodeRgbFromFloat(vColor), vAlpha);
#endif
}
"""

type
    VertexDesc = object
        positionSize: int32
        rotationSize: int32
        scaleSize: int32
        alphaSize: int32
        colorSize: int32
        idSize: int32

    Particle = ref object
        position: Vector3
        rotation, rotationVelocity: Vector3 #deg per sec
        scale: Vector3
        alpha: float32
        id: int
        lifetime: float
        velocity: Vector3
        randStartScale: float

    ParticleSystem* = ref object of Component
        animation*: Animation
        count: int32
        lastBirthTime: float

        vertexBuffer: BufferRef
        indexBuffer: BufferRef
        particlesVertexBuff: seq[float32]
        indexBufferSize: int
        particles: seq[Particle]
        newParticles: seq[Particle]
        vertexDesc: VertexDesc
        worldTransform: Matrix4
        shader*: Shader

        birthRate*: float
        lifetime*: float
        texture*: Image
        startColor*, dstColor*: Vector3
        startScale*, dstScale*: Vector3
        randScaleFrom*, randScaleTo*: float32
        startAlpha*, dstAlpha*: float32
        startVelocity*, randVelocityFrom*, randVelocityTo*: float32
        randRotVelocityFrom*, randRotVelocityTo*: Vector3 # deg
        gravity*: Vector3

        currentTime: float # to calculate normal dt
        lastTime: float
        duration*: float
        remainingDuration: float
        isLooped*: bool
        isPlayed*: bool
        is3dRotation*: bool

        attractorNode*: Node
        attractor*: PSAttractor

        genShapeNode*: Node
        genShape: PSGenShape
        isInited: bool

        lastPos, curPos: Vector3 # data to interpolate particle generation


proc randomBetween(fromV, toV: float32): float32 =
    result = random(fromV - toV) + toV

proc randomBetween(fromV, toV: Vector3): Vector3 =
    result.x = random(fromV.x - toV.x) + toV.x
    result.y = random(fromV.y - toV.y) + toV.y
    result.z = random(fromV.z - toV.z) + toV.z

proc getVertexSizeof(ps: ParticleSystem): int =
    result = (ps.vertexDesc.positionSize + ps.vertexDesc.rotationSize + ps.vertexDesc.scaleSize + ps.vertexDesc.alphaSize)* sizeof(float32) + (ps.vertexDesc.colorSize + ps.vertexDesc.idSize) * sizeof(float32)

proc getVertexSize(ps: ParticleSystem): int =
    result = ps.vertexDesc.positionSize + ps.vertexDesc.rotationSize + ps.vertexDesc.scaleSize + ps.vertexDesc.alphaSize + ps.vertexDesc.idSize + ps.vertexDesc.colorSize

proc newVertexDesc(posSize, rotSize, scSize, aSize, colorSize, idSize: int32): VertexDesc =
    result.positionSize = posSize
    result.rotationSize = rotSize
    result.scaleSize = scSize
    result.alphaSize = aSize
    result.colorSize = colorSize
    result.idSize = idSize

proc transformDirection*(mat: Matrix4, dir: Vector3): Vector3 =
    result.x = dir.x * mat[0] + dir.y * mat[4] + dir.z * mat[8]
    result.y = dir.x * mat[1] + dir.y * mat[5] + dir.z * mat[9]
    result.z = dir.x * mat[2] + dir.y * mat[6] + dir.z * mat[10]

proc createParticle(ps: ParticleSystem, index, count: int, dt: float): Particle =
    result = Particle.new()

    var interpolatePos: Vector3
    var interpolateDt: float
    if count > 0:
        let ic = float(index) / float(count)
        interpolatePos = (ps.curPos - ps.lastPos) * ic
        interpolateDt = dt * ic

    if not ps.genShape.isNil:
        let gData = ps.genShape.generate()
        result.position = ps.worldTransform * (gData.position - interpolatePos)
        result.velocity = ps.worldTransform.transformDirection(gData.direction) * (ps.startVelocity + randomBetween(ps.randVelocityFrom, ps.randVelocityTo))
        result.position += result.velocity * interpolateDt

    result.scale = ps.startScale
    result.randStartScale = randomBetween(ps.randScaleFrom, ps.randScaleTo)
    result.rotation = newVector3(0.0, 0.0, 0.0)
    result.rotationVelocity = randomBetween(ps.randRotVelocityFrom, ps.randRotVelocityTo)
    result.alpha = ps.startAlpha
    result.lifetime = ps.lifetime

proc fillIBuffer(ps: ParticleSystem) =
    let gl = currentContext().gl
    var ib = newSeq[GLushort]()

    ps.indexBufferSize = int(ceil(ps.birthRate) * ceil(ps.lifetime)) * 6
    if ps.indexBufferSize <= 1:
        ps.indexBufferSize = 60000

    for i in 0 ..< ps.indexBufferSize:
        ib.add(GLushort(4*i + 0))
        ib.add(GLushort(4*i + 1))
        ib.add(GLushort(4*i + 2))

        ib.add(GLushort(4*i + 0))
        ib.add(GLushort(4*i + 2))
        ib.add(GLushort(4*i + 3))

    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ps.indexBuffer)
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, ib, gl.STATIC_DRAW)

proc initSystem(ps: ParticleSystem) =
    let gl = currentContext().gl
    ps.animation = newAnimation()
    ps.animation.numberOfLoops = -1

    if ps.is3dRotation:
        ps.vertexDesc = newVertexDesc(3, 3, 2, 1, 1, 1)
    else:
        ps.vertexDesc = newVertexDesc(3, 1, 2, 1, 1, 1)
    ps.particlesVertexBuff = newSeq[float32]( int(ceil(ps.birthRate) * ceil(ps.lifetime)) * ps.getVertexSize() )
    ps.vertexBuffer = gl.createBuffer()
    ps.indexBuffer = gl.createBuffer()
    ps.fillIBuffer()

    ps.newParticles = newSeq[Particle]()
    ps.particles = newSeq[Particle]( int(ceil(ps.birthRate) * ceil(ps.lifetime)) )

    ps.shader = newShader(ParticleVertexShader, ParticleFragmentShader,
            @[(0.GLuint, "aPosition"), (1.GLuint, "aRotation"), (2.GLuint, "aScale"), (3.GLuint, "aAlpha"), (4.GLuint, "aColor"), (5.GLuint, "aID")])

    ps.genShapeNode = ps.node

    ps.currentTime = epochTime()
    ps.lastTime = epochTime()
    ps.remainingDuration = ps.duration
    ps.lastBirthTime = epochTime()

    ps.lastPos = ps.node.translation
    ps.curPos = ps.node.translation

    ps.isInited = true

method init(ps: ParticleSystem) =
    ps.isInited = false
    procCall ps.Component.init()

    ps.count = 0
    ps.birthRate = 100
    ps.lifetime = 8.0

    ps.startVelocity = 8
    ps.randVelocityFrom = 0.0
    ps.randVelocityTo = 0.0
    ps.randRotVelocityFrom = newVector3(0.0, 0.0, 0.0)
    ps.randRotVelocityTo = newVector3(0.0, 0.0, 0.0)
    ps.startAlpha = 1.0
    ps.dstAlpha = 0.0
    ps.startScale = newVector3(3.0, 3.0, 3.0)
    ps.dstScale = newVector3(0.0, 0.0, 0.0)
    ps.randScaleFrom = 0.0
    ps.randScaleTo = 0.0
    ps.gravity = newVector3(0.0, -1.5, 0.0)
    ps.startColor = newVector3(1.0, 1.0, 1.0)
    ps.dstColor = newVector3(1.0, 1.0, 1.0)

    ps.isLooped = true
    ps.duration = 3.0
    ps.isPlayed = true

    ps.is3dRotation = false

proc start(ps: ParticleSystem) =
    ps.isPlayed = true

    ps.currentTime = epochTime()
    ps.lastTime = epochTime()
    ps.lastBirthTime = epochTime()
    ps.remainingDuration = ps.duration

    ps.lastPos = ps.node.translation
    ps.curPos = ps.node.translation

proc stop(ps: ParticleSystem) =
    ps.isPlayed = false

proc decodeRgbToFloat(c: Vector3): float32 =
    float32((int(c[0]*255) + int(c[1]*255) * 256 + int(c[2]*255) * 256 * 256))

template setVector3ToBuffer(buff: var seq[float32], offset: int, vec: Vector3) =
    buff[offset + 0] = vec.x
    buff[offset + 1] = vec.y
    buff[offset + 2] = vec.z

var gCounter = 0.0
proc updateParticlesBuffer(ps: ParticleSystem, dt: float32) =
    gCounter += 0.05
    let xpos = sin(gCounter) * 10
    var newParticlesCount = ps.newParticles.len
    ps.count = 0

    var v1, v2, v3, v4: int
    let vertexSize = ps.getVertexSize()

    for i in 0 ..< ps.particles.len:
        if ps.particles[i].isNil:
            continue

        # if we have dead particle than we insert new from newParticle array
        if ps.particles[i].lifetime <= 0.0 and newParticlesCount > 0:
            newParticlesCount.dec()
            ps.particles[i] = ps.newParticles[newParticlesCount]

        elif ps.particles[i].lifetime <= 0.0:
            continue

        if ps.particlesVertexBuff.len <= (ps.count + 1) * 4 * vertexSize:
            for j in 0 .. 4*vertexSize:
                ps.particlesVertexBuff.add(0.0)

        ps.particles[i].lifetime -= dt
        let normLifeTime = ps.particles[i].lifetime / ps.lifetime
        let oneMinusNormLifeTime = 1.0 - normLifeTime

        v1 = vertexSize* (4 * ps.count + 0) # vertexSize (vertexCount * index + vertexNum)
        v2 = vertexSize* (4 * ps.count + 1)
        v3 = vertexSize* (4 * ps.count + 2)
        v4 = vertexSize* (4 * ps.count + 3)
        var offset = 0

        # positions
        if not ps.attractor.isNil:
            ps.particles[i].velocity += ps.attractor.getForceAtPoint(ps.particles[i].position)

        ps.particles[i].velocity.x += ps.gravity.x*dt
        ps.particles[i].velocity.y += ps.gravity.y*dt
        ps.particles[i].velocity.z += ps.gravity.z*dt
        ps.particles[i].position.x += ps.particles[i].velocity.x*dt
        ps.particles[i].position.y += ps.particles[i].velocity.y*dt
        ps.particles[i].position.z += ps.particles[i].velocity.z*dt

        ps.particlesVertexBuff.setVector3ToBuffer(v1 + offset, ps.particles[i].position)
        ps.particlesVertexBuff.setVector3ToBuffer(v2 + offset, ps.particles[i].position)
        ps.particlesVertexBuff.setVector3ToBuffer(v3 + offset, ps.particles[i].position)
        ps.particlesVertexBuff.setVector3ToBuffer(v4 + offset, ps.particles[i].position)
        offset += ps.vertexDesc.positionSize

        # rotation
        if ps.is3dRotation:
            ps.particles[i].rotation.x += ps.particles[i].rotationVelocity.x * dt
            ps.particles[i].rotation.y += ps.particles[i].rotationVelocity.y * dt
            ps.particles[i].rotation.z += ps.particles[i].rotationVelocity.z * dt

            ps.particlesVertexBuff.setVector3ToBuffer(v1 + offset, ps.particles[i].rotation)
            ps.particlesVertexBuff.setVector3ToBuffer(v2 + offset, ps.particles[i].rotation)
            ps.particlesVertexBuff.setVector3ToBuffer(v3 + offset, ps.particles[i].rotation)
            ps.particlesVertexBuff.setVector3ToBuffer(v4 + offset, ps.particles[i].rotation)
        else:
            ps.particles[i].rotation.z += ps.particles[i].rotationVelocity.z * dt
            ps.particlesVertexBuff[v1 + offset] = ps.particles[i].rotation.z
            ps.particlesVertexBuff[v2 + offset] = ps.particles[i].rotation.z
            ps.particlesVertexBuff[v3 + offset] = ps.particles[i].rotation.z
            ps.particlesVertexBuff[v4 + offset] = ps.particles[i].rotation.z

        offset += ps.vertexDesc.rotationSize

        # scale
        ps.particles[i].scale.x = (ps.startScale.x + ps.particles[i].randStartScale) * normLifeTime + ps.dstScale.x * oneMinusNormLifeTime
        ps.particles[i].scale.y = (ps.startScale.y + ps.particles[i].randStartScale) * normLifeTime + ps.dstScale.y * oneMinusNormLifeTime
        ps.particlesVertexBuff[v1 + offset + 0] = ps.particles[i].scale.x
        ps.particlesVertexBuff[v1 + offset + 1] = ps.particles[i].scale.y

        ps.particlesVertexBuff[v2 + offset + 0] = ps.particles[i].scale.x
        ps.particlesVertexBuff[v2 + offset + 1] = ps.particles[i].scale.y

        ps.particlesVertexBuff[v3 + offset + 0] = ps.particles[i].scale.x
        ps.particlesVertexBuff[v3 + offset + 1] = ps.particles[i].scale.y

        ps.particlesVertexBuff[v4 + offset + 0] = ps.particles[i].scale.x
        ps.particlesVertexBuff[v4 + offset + 1] = ps.particles[i].scale.y
        offset += ps.vertexDesc.scaleSize

        # alpha
        ps.particles[i].alpha = ps.startAlpha * normLifeTime + ps.dstAlpha * oneMinusNormLifeTime
        ps.particlesVertexBuff[v1 + offset] = ps.particles[i].alpha
        ps.particlesVertexBuff[v2 + offset] = ps.particles[i].alpha
        ps.particlesVertexBuff[v3 + offset] = ps.particles[i].alpha
        ps.particlesVertexBuff[v4 + offset] = ps.particles[i].alpha
        offset += ps.vertexDesc.alphaSize

        # color
        let color = decodeRgbToFloat(ps.startColor * normLifeTime + ps.dstColor * oneMinusNormLifeTime)
        ps.particlesVertexBuff[v1 + offset] = color
        ps.particlesVertexBuff[v2 + offset] = color
        ps.particlesVertexBuff[v3 + offset] = color
        ps.particlesVertexBuff[v4 + offset] = color
        offset += ps.vertexDesc.colorSize

        # ID
        ps.particlesVertexBuff[v1 + offset] = 0.0
        ps.particlesVertexBuff[v2 + offset] = 1.0
        ps.particlesVertexBuff[v3 + offset] = 2.0
        ps.particlesVertexBuff[v4 + offset] = 3.0

        ps.count.inc()

    # if we have new particles
    for i in 0 .. newParticlesCount - 1:
        ps.particles.add(ps.newParticles[i])

proc update(ps: ParticleSystem, dt: float) =
    let perParticleTime = 1.0 / ps.birthRate
    let curTime = epochTime()

    ps.worldTransform = ps.node.worldTransform()
    ps.lastPos = ps.curPos
    ps.curPos = ps.node.translation

    if not ps.genShapeNode.isNil:
        ps.genShape = ps.genShapeNode.getComponent(PSGenShape)

    if not ps.attractorNode.isNil:
        ps.attractor = ps.genShapeNode.getComponent(PSAttractor)

    # chek IB size (need for runtime property editing)
    if ps.indexBufferSize < int(ceil(ps.birthRate) * ceil(ps.lifetime)):
        ps.fillIBuffer()

    if (ps.remainingDuration > 0 or ps.isLooped) and ps.isPlayed:
        ps.remainingDuration -= dt

        if curTime - ps.lastBirthTime > perParticleTime:
            let pCount = int((curTime - ps.lastBirthTime) / perParticleTime)
            for i in 0 .. pCount:
                ps.newParticles.add(ps.createParticle(i, pCount, dt))

            ps.lastBirthTime = curTime

    ps.updateParticlesBuffer(dt)
    ps.newParticles.setLen(0)


method draw*(ps: ParticleSystem) =
    ps.currentTime = epochTime()
    let dt = ps.currentTime - ps.lastTime
    ps.lastTime = ps.currentTime
    ps.node.sceneView.setNeedsDisplay()
    let gl = currentContext().gl

    if not ps.isInited:
        ps.initSystem()

    ps.update(dt)

    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ps.indexBuffer)
    gl.bindBuffer(gl.ARRAY_BUFFER, ps.vertexBuffer)
    gl.bufferData(gl.ARRAY_BUFFER, ps.particlesVertexBuff, gl.STATIC_DRAW)

    var offset: int = 0
    let stride = ps.getVertexSizeof()

    gl.enableVertexAttribArray(0)
    gl.vertexAttribPointer(0, ps.vertexDesc.positionSize, gl.FLOAT, false, stride.GLsizei , offset)
    offset += ps.vertexDesc.positionSize * sizeof(GLfloat)

    gl.enableVertexAttribArray(1)
    gl.vertexAttribPointer(1, ps.vertexDesc.rotationSize, gl.FLOAT, false, stride.GLsizei , offset)
    offset += ps.vertexDesc.rotationSize * sizeof(GLfloat)

    gl.enableVertexAttribArray(2)
    gl.vertexAttribPointer(2, ps.vertexDesc.scaleSize, gl.FLOAT, false, stride.GLsizei , offset)
    offset += ps.vertexDesc.scaleSize * sizeof(GLfloat)

    gl.enableVertexAttribArray(3)
    gl.vertexAttribPointer(3, ps.vertexDesc.alphaSize, gl.FLOAT, false, stride.GLsizei , offset)
    offset += ps.vertexDesc.alphaSize * sizeof(GLfloat)

    gl.enableVertexAttribArray(4)
    gl.vertexAttribPointer(4, ps.vertexDesc.colorSize, gl.FLOAT, false, stride.GLsizei , offset)
    offset += ps.vertexDesc.colorSize * sizeof(GLfloat)

    gl.enableVertexAttribArray(5)
    gl.vertexAttribPointer(5, ps.vertexDesc.idSize, gl.FLOAT, false, stride.GLsizei , offset)

    if ps.is3dRotation:
        ps.shader.addDefine("ROTATION_3D")
    else:
        ps.shader.removeDefine("ROTATION_3D")

    var theQuad {.noinit.}: array[4, GLfloat]
    if not ps.texture.isNil:
        gl.activeTexture(gl.TEXTURE0)
        gl.bindTexture(gl.TEXTURE_2D, getTextureQuad(ps.texture, gl, theQuad))
        ps.shader.addDefine("TEXTURED")
    else:
        ps.shader.removeDefine("TEXTURED")

    ps.shader.bindShader()
    ps.shader.setUniform("uTexUnitCoords", theQuad)
    ps.shader.setUniform("texUnit", 0)
    ps.shader.setTransformUniform()

    let sv = ps.node.sceneView
    let viewMatrix = sv.viewMatrix
    var projMatrix : Matrix4
    sv.camera.getProjectionMatrix(sv.bounds, projMatrix)

    ps.shader.setUniform("projMatrix", projMatrix)
    ps.shader.setUniform("viewMatrix", viewMatrix)

    gl.depthMask(false)
    gl.enable(gl.DEPTH_TEST)

    gl.drawElements(gl.TRIANGLES, ps.count * 6, gl.UNSIGNED_SHORT)

    #TODO to default settings
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, invalidBuffer)
    gl.bindBuffer(gl.ARRAY_BUFFER, invalidBuffer)
    gl.disable(gl.DEPTH_TEST)
    gl.activeTexture(gl.TEXTURE0)
    gl.enable(gl.BLEND)
    gl.depthMask(true)


method deserialize*(ps: ParticleSystem, j: JsonNode) =
    if j.isNil:
        return

    j.getSerializedValue("duration", ps.duration)
    j.getSerializedValue("isLooped", ps.isLooped)
    j.getSerializedValue("isPlayed", ps.isPlayed)
    j.getSerializedValue("birthRate", ps.birthRate)
    j.getSerializedValue("lifetime", ps.lifetime)
    j.getSerializedValue("startVelocity", ps.startVelocity)
    j.getSerializedValue("randVelocityFrom", ps.randVelocityFrom)
    j.getSerializedValue("randVelocityTo", ps.randVelocityTo)
    j.getSerializedValue("is3dRotation", ps.is3dRotation)
    j.getSerializedValue("randRotVelocityFrom", ps.randRotVelocityFrom)
    j.getSerializedValue("randRotVelocityTo", ps.randRotVelocityTo)
    j.getSerializedValue("startScale", ps.startScale)
    j.getSerializedValue("dstScale", ps.dstScale)
    j.getSerializedValue("randScaleFrom", ps.randScaleFrom)
    j.getSerializedValue("randScaleTo", ps.randScaleTo)
    j.getSerializedValue("startAlpha", ps.startAlpha)
    j.getSerializedValue("dstAlpha", ps.dstAlpha)
    j.getSerializedValue("startColor", ps.startColor)
    j.getSerializedValue("dstColor", ps.dstColor)
    j.getSerializedValue("gravity", ps.gravity)
    j.getSerializedValue("texture", ps.texture)

    j.getSerializedValue("genShapeNode", ps.genShapeNode)
    j.getSerializedValue("attractorNode", ps.attractorNode)

    ps.initSystem()

method visitProperties*(ps: ParticleSystem, p: var PropertyVisitor) =
    proc onLoopedChange() =
        ps.remainingDuration = ps.duration
        ps.lastBirthTime = epochTime()

    proc onPlayedChange() =
        if ps.isPlayed:
            ps.start()
        else:
            ps.stop()

    proc on3dRotationChange() =
        if ps.is3dRotation:
            ps.vertexDesc = newVertexDesc(3, 3, 2, 1, 1, 1)
        else:
            ps.vertexDesc = newVertexDesc(3, 1, 2, 1, 1, 1)

    p.visitProperty("duration", ps.duration)
    p.visitProperty("isLooped", ps.isLooped, onLoopedChange)
    p.visitProperty("isPlayed", ps.isPlayed, onPlayedChange)
    p.visitProperty("genShapeNode", ps.genShapeNode)
    p.visitProperty("attractorNode", ps.attractorNode)
    p.visitProperty("birthRate", ps.birthRate)
    p.visitProperty("lifetime", ps.lifetime)
    p.visitProperty("startVelocity", ps.startVelocity)
    p.visitProperty("randVelFrom", ps.randVelocityFrom)
    p.visitProperty("randVelTo", ps.randVelocityTo)
    p.visitProperty("is3dRotation", ps.is3dRotation, on3dRotationChange)
    p.visitProperty("randRotVelFrom", ps.randRotVelocityFrom)
    p.visitProperty("randRotVelTo", ps.randRotVelocityTo)
    p.visitProperty("startScale", ps.startScale)
    p.visitProperty("dstScale", ps.dstScale)
    p.visitProperty("randScaleFrom", ps.randScaleFrom)
    p.visitProperty("randScaleTo", ps.randScaleTo)
    p.visitProperty("startAlpha", ps.startAlpha)
    p.visitProperty("dstAlpha", ps.dstAlpha)
    p.visitProperty("startColor", ps.startColor)
    p.visitProperty("dstColor", ps.dstColor)
    p.visitProperty("gravity", ps.gravity)
    p.visitProperty("texture", ps.texture)


registerComponent[ParticleSystem]()
