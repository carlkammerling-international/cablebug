extends Node2D

func _process(delta: float) -> void:
	match global.lives:
		3:
			$life3.visible = true
			$life2.visible = true
			$life1.visible = true
		2:
			$life3.visible = false
			$life2.visible = true
			$life1.visible = true
		1:
			$life3.visible = false
			$life2.visible = false
			$life1.visible = true
		0:
			self.visible = false
